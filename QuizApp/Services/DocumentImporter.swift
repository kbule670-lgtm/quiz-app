import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
#endif

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

    // .docx 走系统自带的 NSAttributedString 读取（不用装任何库）；
    // 老版 .doc（二进制格式）系统在 iOS 上读不了，会走到报错提示另存为 .docx。
    static func fromDocx(_ data: Data) throws -> [QuestionDTO] {
        #if canImport(UIKit)
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.officeOpenXML
        ]
        guard let attr = try? NSAttributedString(data: data, options: options, documentAttributes: nil),
              attr.string.trimmingCharacters(in: .whitespacesAndNewlines).count > 20
        else {
            throw ImportError.badFormat("这个 Word 文件读不出来；如果是老版 .doc，请在 Word/WPS 里另存为 .docx 再导")
        }
        return try QuestionImporter.fromFormattedText(attr.string)
        #else
        throw ImportError.badFormat("当前系统读不了 Word 文件")
        #endif
    }
}
