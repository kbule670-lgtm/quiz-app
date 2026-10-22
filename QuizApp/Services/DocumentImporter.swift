import Foundation
import PDFKit
import ZIPFoundation

// 从 PDF / Word 文件里先把文字抠出来，再交给 QuestionImporter 的文字解析器。
// 只认"有文字层"的文件：扫描件/拍照的 PDF 里没有文字，抠不出来，会明确报错，
// 不会静默导入一堆空白（那种要上 OCR，是另一个工程，v2 再说）。
enum DocumentImporter {

    static func fromPDF(_ data: Data) throws -> [QuestionDTO] {
        guard let doc = PDFDocument(data: data) else {
            throw ImportError.badFormat("这个 PDF 打不开，可能已损坏或加了密码")
        }
        var text = ""
        for i in 0..<doc.pageCount {
            if let pageText = doc.page(at: i)?.string {
                text += pageText + "\n"
            }
        }
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 else {
            throw ImportError.badFormat("这个 PDF 里读不到文字，多半是扫描/图片版；先在 WPS 里转成文字版 PDF 或 Word 再导")
        }
        return try QuestionImporter.fromFormattedText(text)
    }

    // .docx 本质是个 zip 包：解开它，取 word/document.xml，把 XML 标签剥掉就是正文。
    // （之前用 NSAttributedString.DocumentType.officeOpenXML 的写法是 macOS 独有的，
    //   iOS SDK 里没有这个成员、编译不过，2026-10-23 第一次云端编译就是栽在这。）
    // 老版 .doc 是二进制格式、不是 zip，解不开会走到报错，提示另存为 .docx。
    static func fromDocx(_ data: Data) throws -> [QuestionDTO] {
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
        return try QuestionImporter.fromFormattedText(text)
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
