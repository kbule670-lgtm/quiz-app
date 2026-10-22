import SwiftUI
import SwiftData
import UniformTypeIdentifiers

private struct Notice: Identifiable {
    let id = UUID()
    let text: String
}

// 题库页：导入（JSON/CSV/PDF/Word/txt 文件）/ 示例题 / 导出 / 清空
struct ImportView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Question.stem) private var questions: [Question]
    @State private var showImporter = false
    @State private var notice: Notice?
    @State private var showNotice = false
    @State private var confirmClear = false
    @State private var exportURL: URL?

    private let letters = ["A", "B", "C", "D"]

    var body: some View {
        NavigationStack {
            List {
                Section("导入") {
                    Button("从文件导入题库（PDF / Word / JSON / CSV / txt）") { showImporter = true }
                    Button("载入内置示例题") { loadSample() }
                }
                Section("题库（\(questions.count) 道）") {
                    ForEach(questions) { q in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(q.stem).lineLimit(1)
                            Text("\(q.deckName) · 刷过 \(q.totalAttempts) 次，对 \(q.correctAttempts) 次")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete(perform: delete)
                }
                Section("导出 / 清空") {
                    Button("生成题库导出文件") { makeExport() }
                    if let url = exportURL {
                        ShareLink("分享题库 JSON 文件", item: url)
                    }
                    Button("清空题库", role: .destructive) { confirmClear = true }
                }
            }
            .navigationTitle("题库")
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.json, .commaSeparatedText, .pdf, .plainText,
                                      UTType("org.openxmlformats.wordprocessingml.document") ?? .data]
            ) { result in
                handleImport(result)
            }
            .alert("提示", isPresented: $showNotice, presenting: notice) { _ in } message: { n in
                Text(n.text)
            }
            .confirmationDialog("确定清空整个题库？这个操作不能撤销。",
                                isPresented: $confirmClear,
                                titleVisibility: .visible) {
                Button("清空", role: .destructive) { clearAll() }
            }
        }
    }

    private func say(_ text: String) {
        notice = Notice(text: text)
        showNotice = true
    }

    private func handleImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            guard url.startAccessingSecurityScopedResource() else {
                say("打不开这个文件，换个位置再试一次"); return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            let dtos: [QuestionDTO]
            let ext = url.pathExtension.lowercased()
            switch ext {
            case "csv":
                let text = try String(contentsOf: url, encoding: .utf8)
                dtos = try QuestionImporter.fromCSV(text)
            case "pdf":
                dtos = try DocumentImporter.fromPDF(try Data(contentsOf: url))
            case "docx":
                dtos = try DocumentImporter.fromDocx(try Data(contentsOf: url))
            case "doc":
                say("老版 .doc 读不了，在 Word/WPS 里另存为 .docx 再导一次"); return
            case "txt":
                let text = try String(contentsOf: url, encoding: .utf8)
                dtos = try QuestionImporter.fromFormattedText(text)
            default:
                let data = try Data(contentsOf: url)
                dtos = try QuestionImporter.fromJSON(data)
            }
            guard !dtos.isEmpty else { say("文件里没有读到题目"); return }
            insert(dtos, deckName: url.deletingPathExtension().lastPathComponent)
            say("导入成功：\(dtos.count) 道题")
        } catch {
            say("导入失败：\(error.localizedDescription)")
        }
    }

    private func insert(_ dtos: [QuestionDTO], deckName: String) {
        for d in dtos {
            context.insert(Question(stem: d.stem, options: d.options,
                                    answerIndex: d.answerIndex,
                                    explanation: d.explanation, deckName: deckName))
        }
        try? context.save()
    }

    private func loadSample() {
        insert(SampleBank.questions, deckName: "示例题库")
        say("已载入 \(SampleBank.questions.count) 道示例题，可以先跑通全流程")
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets { context.delete(questions[i]) }
        try? context.save()
    }

    private func clearAll() {
        for q in questions { context.delete(q) }
        try? context.save()
    }

    private func makeExport() {
        let arr: [[String: Any]] = questions.map { q in
            ["stem": q.stem,
             "options": q.options,
             "answer": letters[q.answerIndex],
             "explanation": q.explanation]
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: arr, options: [.prettyPrinted, .sortedKeys])
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("题库导出.json")
            try data.write(to: url)
            exportURL = url
        } catch {
            say("导出失败：\(error.localizedDescription)")
        }
    }
}
