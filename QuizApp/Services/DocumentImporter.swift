import Foundation
import PDFKit
import UIKit
import Vision
import ZIPFoundation

// 从 PDF / Word 文件里先把文字抠出来，再交给 QuestionImporter 的文字解析器。
// PDF 先走文字层；没有文字层（整本都是图片，比如截图拼的题库）就走系统自带的
// 文字识别（Vision，中文印刷体）逐页认，进度通过回调报给导入页显示。
enum DocumentImporter {

    static func fromPDF(_ data: Data,
                        progress: @escaping (Int, Int) -> Void) async throws
        -> (dtos: [QuestionDTO], skipped: Int, blocks: Int, preview: String) {
        let text = try await pdfText(data, progress: progress)
        let r = try QuestionImporter.parseFormattedText(text)
        return (r.dtos, r.skipped.count, r.blocks, preview(of: text))
    }

    // 只把 PDF 的文字抠出来（有文字层直接读，没有就逐页 OCR），先不解析。
    // AI 解析路径要用原文，所以单独拆出来。
    static func pdfText(_ data: Data,
                        progress: @escaping (Int, Int) -> Void) async throws -> String {
        guard let doc = PDFDocument(data: data) else {
            throw ImportError.badFormat("这个 PDF 打不开，可能已损坏或加了密码")
        }
        var text = ""
        for i in 0..<doc.pageCount {
            if let pageText = doc.page(at: i)?.string {
                text += pageText + "\n"
            }
        }
        text = stripRepeatedPageLines(text)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 {
            return text
        }
        // 没有文字层：整本是图片，逐页 OCR
        let ocr = await ocrText(from: doc, progress: progress)
        let cleaned = stripRepeatedPageLines(ocr)
        guard cleaned.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 else {
            throw ImportError.badFormat("这个 PDF 全是图片，自动识别也没读出文字（图片太糊的话识别不了），换个清晰点的版本再试")
        }
        return cleaned
    }

    // 导入失败时给用户看的诊断：识别出的文字开头一截，方便截图定位问题
    private static func preview(of text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(t.prefix(120))
    }

    // 逐页把 PDF 页面渲染成图，用 Vision 认字。识别顺序按版面从上到下排。
    // 每页必须包在 autoreleasepool 里渲染完立刻释放：渲染图是自动释放对象，
    // 后台循环里不包的话几十页就攒爆内存被系统杀掉（v3 实测跑到 48 页闪退）。
    private static func ocrText(from doc: PDFDocument,
                                progress: @escaping (Int, Int) -> Void) async -> String {
        var all = ""
        for i in 0..<doc.pageCount {
            let pageText: String = autoreleasepool {
                guard let page = doc.page(at: i) else { return "" }
                let bounds = page.bounds(for: .cropBox)
                guard bounds.width > 1, bounds.height > 1 else { return "" }
                // 源图本身只有约 96 dpi，渲染倍数给 2 倍足够，再高只是插值、徒增内存
                let scale: CGFloat = 2.0
                let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
                let renderer = UIGraphicsImageRenderer(size: size)
                let image = renderer.image { ctx in
                    UIColor.white.setFill()
                    ctx.fill(CGRect(origin: .zero, size: size))
                    let c = ctx.cgContext
                    c.translateBy(x: 0, y: size.height)
                    c.scaleBy(x: scale, y: -scale)
                    page.draw(with: .cropBox, to: c)
                }
                guard let cg = image.cgImage else { return "" }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["zh-Hans", "en-US"]
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                try? handler.perform([request])
                let found = (request.results as? [VNRecognizedTextObservation]) ?? []
                let observations = found.sorted { a, b in
                    if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.008 {
                        return a.boundingBox.midY > b.boundingBox.midY
                    }
                    return a.boundingBox.minX < b.boundingBox.minX
                }
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                return lines.joined(separator: "\n")
            }
            all += pageText + "\n"
            progress(i + 1, doc.pageCount)
        }
        return all
    }

    // .docx 本质是个 zip 包：解开它，取 word/document.xml，把 XML 标签剥掉就是正文。
    // 老版 .doc 是二进制格式、不是 zip，解不开会走到报错，提示另存为 .docx。
    static func fromDocx(_ data: Data) throws
        -> (dtos: [QuestionDTO], skipped: Int, blocks: Int, preview: String) {
        let text = try docxText(data)
        let r = try QuestionImporter.parseFormattedText(text)
        return (r.dtos, r.skipped.count, r.blocks, preview(of: text))
    }

    // 只把 .docx 的正文文字抠出来，先不解析（AI 解析路径用）
    static func docxText(_ data: Data) throws -> String {
        guard let archive = try? Archive(data: data, accessMode: .read),
              let entry = archive["word/document.xml"]
        else {
            throw ImportError.badFormat("这个 Word 文件读不出来；如果是老版 .doc，请在 Word/WPS 里另存为 .docx 再导")
        }
        var xmlData = Data()
        do {
            _ = try archive.extract(entry) { chunk in xmlData.append(chunk) }
        } catch {
            throw ImportError.badFormat("这个 Word 文件解不开，可能已损坏")
        }
        guard let xml = String(data: xmlData, encoding: .utf8) else {
            throw ImportError.badFormat("这个 Word 文件的文字编码读不出来")
        }
        let text = plainText(fromDocumentXML: xml)
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 else {
            throw ImportError.badFormat("这个 Word 文件里没读到多少文字，检查一下文件是不是空的")
        }
        return text
    }

    // 页眉页脚清理：同一行短文字在全书重复出现很多次（比如题库水印名），
    // 大概率是页眉页脚，删掉免得粘到题干/选项里。答案行、选项行、题号行永不删。
    static func stripRepeatedPageLines(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var counts: [String: Int] = [:]
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { counts[t, default: 0] += 1 }
        }
        return lines.filter { raw in
            let t = raw.trimmingCharacters(in: .whitespaces)
            let c = counts[t] ?? 0
            // 结构行（答案/解析/选项/题号开头）永不删，哪怕重复再多次
            if t.hasPrefix("答案") || t.hasPrefix("解析") { return true }
            if let f = t.first, "ABCDE".contains(f) || f.isNumber || f == "[" || f == "【" {
                return true
            }
            if t.count <= 12, c >= 4 { return false } // 短页眉水印
            if t.count <= 40, c >= 20 { return false } // 每页都有的页脚注（如更新说明那行）
            return true
        }.joined(separator: "\n")
    }

    // document.xml → 纯文字：段落末尾变回车，剥掉所有标签，再把 XML 转义符还原
    static func plainText(fromDocumentXML xml: String) -> String {
        var s = xml
        s = s.replacingOccurrences(of: "</w:p>", with: "\n")
        s = s.replacingOccurrences(of: #"<w:tab[^>]*/>"#, with: "\t",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: #"<w:br[^>]*/>"#, with: "\n",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&apos;", with: "'")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        return s
    }
}
