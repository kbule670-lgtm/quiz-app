import Foundation
import PDFKit
import UIKit
import Vision
import ZIPFoundation

// 从 PDF / Word 文件里先把文字抠出来，再交给 QuestionImporter 的文字解析器。
// PDF 先走文字层；没有文字层（整本都是图片，比如截图拼的题库）就走系统自带的
// 文字识别（Vision，中文印刷体）逐页认，进度通过回调报给导入页显示。
//
// 8.ipa 改动：
// 1) OCR 逐页原子化存档：每页识别完立即原子写入沙盒临时文件（先落盘、后标记），
//    只有写成功才算该页「仅 OCR 完成」；App 被系统终止后重开，未完成页继续识别，
//    绝不重新识别全书。存档按文件指纹分目录，同一文件字节不变则页文本可复用。
// 2) OCR 行带页内纵坐标（Vision boundingBox midY），供清理器做页面位置判断；
//    文字层 PDF 没有坐标，走回退规则（见 ImportDiagnostics）。
// 3) 清理改走 8.ipa 新规则（页面位置＋跨页比例＋语义保护），清理器版本记入存档。
enum DocumentImporter {

    static func fromPDF(_ data: Data,
                        progress: @escaping (Int, Int) -> Void) async throws
        -> (dtos: [QuestionDTO], skipped: Int, blocks: Int, preview: String) {
        let text = try await pdfText(data, progress: progress)
        let r = try QuestionImporter.parseFormattedText(text)
        return (r.dtos, r.skipped.count, r.blocks, preview(of: text))
    }

    // 只把 PDF 的文字抠出来（有文字层直接读，没有就逐页 OCR），先不解析。
    // AI 解析路径要用原文，所以单独拆出来（兼容旧签名，诊断信息丢弃）。
    static func pdfText(_ data: Data,
                        progress: @escaping (Int, Int) -> Void) async throws -> String {
        let fingerprint = QuestionImporter.sha256Hex(data)
        return try await pdfTextDetailed(data, fingerprint: fingerprint,
                                         progress: progress).text
    }

    // 带诊断的 PDF 取字：返回清理后文本、OCR 行（含坐标）、页统计。
    struct PDFTextResult {
        var text: String
        var lines: [OCRLine]       // 清理后的行（带坐标）
        var rawText: String        // 清理前的 OCR/文字层原文（诊断与重算用）
        var rawLines: [OCRLine]    // 清理前的行
        var cleanup: CleanupReport // 本次清理的报告（诊断 B 段）
        var pagesDone: Int
        var pagesTotal: Int
        var blankPages: [Int]      // 空白或低字符页（页码从 1 计）
        var usedArchive: Bool      // 是否复用了存档页
        var isOCR: Bool            // 是否走了 OCR（否则为文字层）
    }

    static func pdfTextDetailed(_ data: Data, fingerprint: String,
                                progress: @escaping (Int, Int) -> Void) async throws -> PDFTextResult {
        guard let doc = PDFDocument(data: data) else {
            throw ImportError.badFormat("这个 PDF 打不开，可能已损坏或加了密码")
        }
        // 先看文字层：有足量文字就直接用（行无坐标，走回退清理）
        var layerText = ""
        var layerLines: [OCRLine] = []
        var layerBlank: [Int] = []
        for i in 0..<doc.pageCount {
            let pageText = doc.page(at: i)?.string ?? ""
            layerLines += pageText.components(separatedBy: "\n").map {
                OCRLine(text: $0, page: i, midY: nil)
            }
            if pageText.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
                layerBlank.append(i + 1)
            }
            layerText += pageText + "\n"
        }
        if layerText.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 {
            var (kept, report) = ImportCleaner.metaClean(lines: layerLines,
                                                         totalPages: doc.pageCount)
            report.markersBefore = QuestionImporter.markerCount(in: layerText)
            report.markersAfter = QuestionImporter.markerCount(
                in: kept.map(\.text).joined(separator: "\n"))
            return PDFTextResult(text: kept.map(\.text).joined(separator: "\n"),
                                 lines: kept, rawText: layerText, rawLines: layerLines,
                                 cleanup: report,
                                 pagesDone: doc.pageCount, pagesTotal: doc.pageCount,
                                 blankPages: layerBlank, usedArchive: false, isOCR: false)
        }
        // 没有文字层：整本是图片，逐页 OCR（带存档续跑）；ocrText 内部已做新规则清理
        let ocr = await ocrText(from: doc, fingerprint: fingerprint, progress: progress)
        let cleaned = ocr.lines.map(\.text).joined(separator: "\n")
        guard cleaned.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 else {
            throw ImportError.badFormat("这个 PDF 全是图片，自动识别也没读出文字（图片太糊的话识别不了），换个清晰点的版本再试")
        }
        return PDFTextResult(text: cleaned, lines: ocr.lines, rawText: ocr.rawText,
                             rawLines: ocr.rawLines, cleanup: ocr.cleanup,
                             pagesDone: doc.pageCount,
                             pagesTotal: doc.pageCount, blankPages: ocr.blankPages,
                             usedArchive: ocr.usedArchive, isOCR: true)
    }

    // 导入失败时给用户看的诊断：识别出的文字开头一截，方便截图定位问题
    private static func preview(of text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(t.prefix(120))
    }

    // MARK: - 逐页 OCR 存档（原子写、先落盘后标记）

    static func archiveDir(fingerprint: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("quiz-import-\(fingerprint.prefix(16))")
    }

    private static func pageFile(fingerprint: String, page: Int) -> URL {
        archiveDir(fingerprint: fingerprint).appendingPathComponent("page-\(page).json")
    }

    // 读存档页：文件不存在或解码失败都视为无存档（下一页重认，不报错）
    static func loadPageRecord(fingerprint: String, page: Int) -> OCRPageRecord? {
        guard let data = try? Data(contentsOf: pageFile(fingerprint: fingerprint, page: page)),
              let record = try? JSONDecoder().decode(OCRPageRecord.self, from: data),
              record.page == page else { return nil }
        return record
    }

    // 写存档页：原子写；只有返回 true 才算该页已落盘（调用方据此标记 stage）。
    @discardableResult
    static func savePageRecord(fingerprint: String, record: OCRPageRecord) -> Bool {
        let dir = archiveDir(fingerprint: fingerprint)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(record)
            try data.write(to: pageFile(fingerprint: fingerprint, page: record.page),
                           options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    // 整批更新存档页的 stage（清理/入库完成后调用；失败的页保持原 stage，下次续跑）
    static func markArchiveStage(fingerprint: String, pageCount: Int, stage: PageStage) {
        for page in 0..<pageCount {
            guard var record = loadPageRecord(fingerprint: fingerprint, page: page) else {
                continue
            }
            record.stage = stage
            _ = savePageRecord(fingerprint: fingerprint, record: record)
        }
    }

    // 读回已保存的 OCR 原文＋行坐标（供导入完成后重算、未来清理器升级时复用，
    // 无需重新识别）。只认 recognized 的页；任一页缺失即返回 nil，不拿半截文本充数。
    // 注意：导入成功后存档不删除（清理临时文件是“可”不是“必须”），正是为了这条重算路。
    static func archivedText(fingerprint: String, pageCount: Int)
        -> (text: String, lines: [OCRLine])? {
        var lines: [OCRLine] = []
        for page in 0..<pageCount {
            guard let record = loadPageRecord(fingerprint: fingerprint, page: page),
                  record.recognized else { return nil }
            lines += record.lines.isEmpty
                ? record.text.components(separatedBy: "\n").map {
                    OCRLine(text: $0, page: page, midY: nil)
                }
                : record.lines
        }
        guard !lines.isEmpty else { return nil }
        return (lines.map(\.text).joined(separator: "\n"), lines)
    }

    static func clearArchive(fingerprint: String) {
        try? FileManager.default.removeItem(at: archiveDir(fingerprint: fingerprint))
    }

    // 逐页把 PDF 页面渲染成图，用 Vision 认字。识别顺序按版面从上到下排。
    // 每页必须包在 autoreleasepool 里渲染完立刻释放：渲染图是自动释放对象，
    // 后台循环里不包的话几十页就攒爆内存被系统杀掉（v3 实测跑到 48 页闪退）。
    // 存档续跑：已有 stage ≥ ocrDone 且识别成功的页直接复用文本，不再跑 Vision；
    // 识别失败/无存档的页重新识别，识别完先原子落盘、落盘成功才算完成。
    private struct OCRResult {
        var lines: [OCRLine]      // 清理后的行（带坐标）
        var rawText: String
        var rawLines: [OCRLine]
        var cleanup: CleanupReport
        var blankPages: [Int]
        var usedArchive: Bool
    }

    private static func ocrText(from doc: PDFDocument, fingerprint: String,
                                progress: @escaping (Int, Int) -> Void) async -> OCRResult {
        var rawLines: [OCRLine] = []
        var blankPages: [Int] = []
        var usedArchive = false
        for i in 0..<doc.pageCount {
            let pageLines: [OCRLine]
            if let record = loadPageRecord(fingerprint: fingerprint, page: i),
               record.stage == .ocrDone || record.stage == .cleaned
                || record.stage == .split || record.stage == .inserted,
               record.recognized {
                // 存档复用：不跑 Vision。stage 本身就是「已处理完成」的证明，
                // 不是「有文本」——无 stage 的旧文件一律不认。
                // 存档里有行坐标就直接用（走真实位置规则）；老存档无行数据时
                // 回退到按行切分（坐标 nil，走回退规则＋白名单）
                pageLines = record.lines.isEmpty
                    ? record.text.components(separatedBy: "\n").map {
                        OCRLine(text: $0, page: i, midY: nil)
                    }
                    : record.lines
                usedArchive = true
            } else {
                let recognized = autoreleasepool { () -> [OCRLine] in
                    guard let page = doc.page(at: i) else { return [] }
                    let bounds = page.bounds(for: .cropBox)
                    guard bounds.width > 1, bounds.height > 1 else { return [] }
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
                    guard let cg = image.cgImage else { return [] }
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
                    return observations.compactMap { obs in
                        guard let s = obs.topCandidates(1).first?.string else { return nil }
                        return OCRLine(text: s, page: i,
                                       midY: Double(obs.boundingBox.midY))
                    }
                }
                pageLines = recognized
                // 先落盘、后标记：只有原子写成功，才算该页「仅 OCR 完成」
                let text = recognized.map(\.text).joined(separator: "\n")
                let ok = savePageRecord(
                    fingerprint: fingerprint,
                    record: OCRPageRecord(page: i, text: text, lines: recognized,
                                          recognized: !text.trimmingCharacters(
                                            in: .whitespacesAndNewlines).isEmpty,
                                          cleanerVersion: CleanerVersion.current,
                                          stage: .ocrDone))
                _ = ok  // 写失败也不中断导入：本页文本仍在内存里用，下次重开会重新识别该页
            }
            let pageText = pageLines.map(\.text).joined(separator: "\n")
            if pageText.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
                blankPages.append(i + 1)
            }
            rawLines += pageLines
            progress(i + 1, doc.pageCount)
        }
        let rawText = rawLines.map(\.text).joined(separator: "\n")
        var (kept, report) = ImportCleaner.metaClean(lines: rawLines, totalPages: doc.pageCount)
        report.markersBefore = QuestionImporter.markerCount(in: rawText)
        report.markersAfter = QuestionImporter.markerCount(
            in: kept.map(\.text).joined(separator: "\n"))
        // 清理完成：存档页 stage 推进到 cleaned（逐页原子写，失败的页保持 ocrDone）
        for page in 0..<doc.pageCount {
            if var record = loadPageRecord(fingerprint: fingerprint, page: page),
               record.stage == .ocrDone {
                record.stage = .cleaned
                record.cleanerVersion = CleanerVersion.current
                _ = savePageRecord(fingerprint: fingerprint, record: record)
            }
        }
        return OCRResult(lines: kept, rawText: rawText, rawLines: rawLines,
                         cleanup: report, blankPages: blankPages, usedArchive: usedArchive)
    }

    // .docx 本质是个 zip 包：解开它，取 word/document.xml，把 XML 标签剥掉就是正文。
    // 老版 .doc 是二进制格式、不是 zip，解不开会走到报错，提示另存为 .docx。
    static func fromDocx(_ data: Data) throws
        -> (dtos: [QuestionDTO], skipped: Int, blocks: Int, preview: String) {
        let text = try docxText(data)
        let r = try QuestionImporter.parseFormattedText(text)
        return (r.dtos, r.skipped.count, r.blocks, preview(of: text))
    }

    // 只把 .docx 的正文文字抠出来（有文字层直接读，没有就逐页 OCR），先不解析（AI 解析路径用）
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

    // 页眉页脚清理（8.ipa）：OCR 行走新规则（页面位置＋跨页比例＋语义保护），
    // 纯文本行（无坐标）走回退规则＋白名单。旧的 stripRepeatedPageLines 文本版
    // 入口保留，内部改走同一规则，避免两套口径。
    static func stripRepeatedPageLines(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").enumerated().map {
            OCRLine(text: $0.element, page: 0, midY: nil)
        }
        let (kept, _) = ImportCleaner.metaClean(lines: lines, totalPages: 1)
        return kept.map(\.text).joined(separator: "\n")
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
