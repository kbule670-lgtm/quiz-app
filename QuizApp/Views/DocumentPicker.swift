import SwiftUI
import UIKit
import UniformTypeIdentifiers

// 原生文件选择器（不用 SwiftUI 的 fileImporter）
// 2026-10-23 真机实测教训：fileImporter 按类型过滤时，把他那份 PDF 置灰点不动
// （iOS 27 Beta 上类型识别有问题）。这里放开成所有文件都能选（.item），
// 选回来 App 自己按扩展名分发，不支持的格式会明确报错，不会再出现"点不动"。
struct DocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // asCopy=true：系统先把文件复制进 App 临时目录，省去权限勾兑，选完直接读
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}
