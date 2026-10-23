import SwiftUI
import SwiftData
import UniformTypeIdentifiers

private struct Notice: Identifiable {
    let id = UUID()
    let text: String
}

// 题库页：导入（PDF/Word/JSON/CSV/txt，三种解析方式）/ 搜索 / 按批次折叠分组 /
// 点题目看详情 / 示例题 / 导出 / 清空
struct ImportView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Question.stem) private var questions: [Question]
    @State private var showImporter = false
    @State private var notice: Notice?
    @State private var showNotice = false
    @State private var confirmClear = false
    @State private var exportURL: URL?
    @State private var importStatus: String?
    @State private var searchText = ""
    @State private var expandedBatches: Set<String> = []

    // 解析方式：普通解析 / 本地 AI / 云端 AI（存 AppStorage）
    @AppStorage("ai.mode") private var modeRaw = ImportAIMode.normal.rawValue
    @AppStorage("ai.provider") private var providerRaw = AIProvider.deepseek.rawValue
    @State private var aiKeyText = ""
    @State private var aiModelText = ""

    private var aiMode: ImportAIMode { ImportAIMode(rawValue: modeRaw) ?? .normal }
    private var provider: AIProvider { AIProvider(rawValue: providerRaw) ?? .deepseek }
    private let letters = ["A", "B", "C", "D", "E"]

    // MARK: - 分组与搜索

    private struct Batch: Identifiable {
        var id: String
        var title: String
        var date: Date?
        var items: [Question]
    }

    // 按导入批次分组：新导入的在前；老数据没有批次号，按题库名归组垫底
    private var batches: [Batch] {
        let grouped = Dictionary(grouping: questions) { q in
            q.batchID ?? "legacy-\(q.deckName)"
        }
        return grouped.map { key, items in
            Batch(id: key,
                  title: items.first?.deckName ?? "题库",
                  date: items.compactMap(\.importedAt).max(),
                  items: items)
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    private var searchResults: [Question] {
        let key = searchText.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return [] }
        return questions.filter { $0.stem.localizedCaseInsensitiveContains(key) }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                modeSection
                Section("导入") {
                    Button(importButtonTitle) { showImporter = true }
                        .disabled(importStatus != nil)
                    Button("载入内置示例题") { loadSample() }
                }
                if let status = importStatus {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(status).font(.callout)
                        }
                    }
                }
                if isSearching {
                    Section("搜索到 \(searchResults.count) 道") {
                        ForEach(searchResults) { q in questionRow(q) }
                            .onDelete { offsets in
                                delete(searchResults, at: offsets)
                            }
                    }
                } else {
                    Section("题库（\(questions.count) 道）") {
                        if questions.isEmpty {
                            Text("还没有题目，先导入一份题库试试")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(batches) { batch in
                            batchHeader(batch)
                            if expandedBatches.contains(batch.id) {
                                ForEach(batch.items) { q in questionRow(q) }
                                    .onDelete { offsets in
                                        delete(batch.items, at: offsets)
                                    }
                            }
                        }
                    }
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
            .searchable(text: $searchText, prompt: "搜索题目")
            .sheet(isPresented: $showImporter) {
                DocumentPicker { url in handleImportURL(url) }
            }
            .alert("提示", isPresented: $showNotice, presenting: notice) { _ in } message: { n in
                Text(n.text)
            }
            .confirmationDialog("确定清空整个题库？这个操作不能撤销。",
                                isPresented: $confirmClear,
                                titleVisibility: .visible) {
                Button("清空", role: .destructive) { clearAll() }
            }
            .onAppear {
                // 第一次打开且这台设备支持本地 AI：默认推荐本地 AI（免费、不用 key）
                if UserDefaults.standard.object(forKey: "ai.mode") == nil,
                   LocalAIParseService.isAvailable {
                    modeRaw = ImportAIMode.local.rawValue
                }
                reloadAIFields()
            }
            .onChange(of: providerRaw) { _ in reloadAIFields() }
        }
    }

    private var importButtonTitle: String {
        switch aiMode {
        case .local: return "从文件导入题库（本地 AI 解析）"
        case .cloud: return "从文件导入题库（云端 AI 解析）"
        case .normal: return "从文件导入题库（PDF / Word / JSON / CSV / txt）"
        }
    }

    // 文件夹式小条：文件名 + 题数 + 展开箭头，默认折叠，点一下展开/收起
    private func batchHeader(_ batch: Batch) -> some View {
        Button {
            if expandedBatches.contains(batch.id) {
                expandedBatches.remove(batch.id)
            } else {
                expandedBatches.insert(batch.id)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").foregroundStyle(.blue)
                Text(batch.title).bold().lineLimit(1)
                Text("\(batch.items.count) 道")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let date = batch.date {
                    Text(date, format: .dateTime.month().day())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: expandedBatches.contains(batch.id) ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
    }

    private func questionRow(_ q: Question) -> some View {
        NavigationLink {
            QuestionDetailView(question: q)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(q.stem).lineLimit(1)
                Text("\(q.isMulti ? "多选" : (q.options.count == 2 ? "判断" : "单选")) · 刷过 \(q.totalAttempts) 次，对 \(q.correctAttempts) 次")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 解析方式区（普通解析 / 本地 AI / 云端 AI 三选一）

    private var modeSection: some View {
        Section {
            Picker("解析方式", selection: $modeRaw) {
                Text("普通解析").tag(ImportAIMode.normal.rawValue)
                if LocalAIParseService.isAvailable {
                    Text("本地 AI").tag(ImportAIMode.local.rawValue)
                }
                Text("云端 AI").tag(ImportAIMode.cloud.rawValue)
            }
            .pickerStyle(.segmented)
            switch aiMode {
            case .normal:
                Text("不用 AI，手机自己按格式抠题：最快、免费；但文件里水印多、排版乱时容易漏题。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .local:
                Text("用 iPhone 自带的苹果智能模型在本机整理题目：免费、不用 key、不用联网，分题型、清格式都帮你做。分段细，整本导完会比云端慢一些，准确率稍低一点。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .cloud:
                cloudSettings
            }
        } header: {
            Text("题目解析方式")
        } footer: {
            Text("导入流程：选文件 → 自动识别文字 → 按选的方式解析 → 题目直接入库，结果会弹出计数。")
        }
    }

    @ViewBuilder
    private var cloudSettings: some View {
        Picker("服务商", selection: $providerRaw) {
            ForEach(AIProvider.allCases) { p in
                Text(p.displayName).tag(p.rawValue)
            }
        }
        TextField("API key", text: $aiKeyText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: aiKeyText) { newValue in AISettings.setApiKey(newValue, for: provider) }
        if aiKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("还差一步：把 API key 填上，导入时云端 AI 才能干活。")
                .font(.callout)
                .foregroundStyle(.orange)
        } else {
            Label("key 已填好，选文件导入就会走云端 AI 解析", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        }
        TextField("模型名", text: $aiModelText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: aiModelText) { newValue in AISettings.setModel(newValue, for: provider) }
        if provider == .doubao {
            Text("豆包这里填的不是模型名，是方舟控制台里建的「接入点 ID」（ep- 开头那串）。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("模型名已填了官方现行的默认值，一般不用动；以后官方换了新模型，把这里改成新名字就能继续用。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Text("key 在服务商官网注册后复制到这里，谁用谁填自己的。按量付费、不是包月，只在导入时才会调用。云端 AI 最准：水印、广告、页眉页脚自动清掉，单选多选判断分好类。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func reloadAIFields() {
        aiKeyText = AISettings.apiKey(for: provider)
        aiModelText = AISettings.model(for: provider)
    }

    // MARK: - 导入

    private func say(_ text: String) {
        notice = Notice(text: text)
        showNotice = true
    }

    private func handleImportURL(_ url: URL) {
        let deckName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()
        let textKinds = ["pdf", "docx", "txt"]
        // 云端 AI + 文字类文件：先查 key 和模型名，没填就别白跑一遍 OCR
        if aiMode == .cloud && textKinds.contains(ext) {
            if AISettings.apiKey(for: provider)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                say("你选了云端 AI 解析，但还没填 API key。先在题库页顶上把 key 填上再导入，或者换成本地 AI / 普通解析。")
                return
            }
            if AISettings.model(for: provider)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                say("你选了云端 AI 解析，但还没填模型名/接入点 ID。先在题库页顶上填好再导入。")
                return
            }
        }
        importStatus = "正在读取文件…"
        let mode = aiMode
        let currentProvider = provider
        Task {
            do {
                let result = try await Self.load(from: url, mode: mode,
                                                 provider: currentProvider) { status in
                    DispatchQueue.main.async { importStatus = status }
                }
                importStatus = nil
                guard !result.dtos.isEmpty else {
                    var msg = "文件里没有读到题目"
                    if !result.debug.isEmpty { msg += "\n" + result.debug }
                    say(msg)
                    return
                }
                insert(result.dtos, deckName: deckName)
                var msg = "导入成功：\(result.dtos.count) 道题"
                if result.skipped > 0 {
                    msg += "\n另有 \(result.skipped) 道没认出来，已跳过（多半是排版或图片识别的问题）"
                }
                if !result.note.isEmpty { msg += "\n" + result.note }
                say(msg)
            } catch {
                importStatus = nil
                say("导入失败：\(error.localizedDescription)")
            }
        }
    }

    private struct LoadOutcome {
        var dtos: [QuestionDTO]
        var skipped: Int
        var debug: String  // 失败时给用户看的诊断（切出几个题块、文字长什么样）
        var note: String   // 成功时附带的一句说明（如 AI 有几段回退了本地解析）
    }

    // 实际读文件+解析。PDF 图片版会先逐页 OCR（慢，放后台跑）；
    // 解析方式三选一：普通解析走本地正则；本地/云端 AI 逐段结构化，某段失败自动回退普通解析。
    private static func load(from url: URL, mode: ImportAIMode, provider: AIProvider,
                             status: @escaping (String) -> Void) async throws -> LoadOutcome {
        // asCopy 复制来的文件在临时目录，一般不用权限；保险起见试一下，有就用完释放
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "csv":
            let text = try String(contentsOf: url, encoding: .utf8)
            return LoadOutcome(dtos: try QuestionImporter.fromCSV(text),
                               skipped: 0, debug: "", note: "")
        case "doc":
            throw ImportError.badFormat("老版 .doc 读不了，在 Word/WPS 里另存为 .docx 再导一次")
        case "pdf", "docx", "txt":
            let text: String
            if ext == "pdf" {
                text = try await DocumentImporter.pdfText(try Data(contentsOf: url)) { cur, total in
                    status("这份 PDF 是图片版的，正在逐页识别文字：第 \(cur)/\(total) 页，耐心等一下")
                }
            } else if ext == "docx" {
                text = try DocumentImporter.docxText(try Data(contentsOf: url))
            } else {
                text = try String(contentsOf: url, encoding: .utf8)
            }
            switch mode {
            case .cloud:
                let outcome = try await AIParseService.parse(text: text, provider: provider) { cur, total in
                    status("云端 AI 解析中 第 \(cur)/\(total) 段")
                }
                var note = ""
                if outcome.fallbackChunks > 0 {
                    note = "其中 \(outcome.fallbackChunks)/\(outcome.totalChunks) 段 AI 没成功，已用普通解析顶上"
                }
                return LoadOutcome(dtos: outcome.dtos, skipped: outcome.skipped,
                                   debug: "", note: note)
            case .local where LocalAIParseService.isAvailable:
                let outcome = try await LocalAIParseService.parse(text: text) { cur, total in
                    status("本地 AI 解析中 第 \(cur)/\(total) 段")
                }
                var note = ""
                if outcome.fallbackChunks > 0 {
                    note = "其中 \(outcome.fallbackChunks)/\(outcome.totalChunks) 段本地 AI 没成功，已用普通解析顶上"
                }
                return LoadOutcome(dtos: outcome.dtos, skipped: outcome.skipped,
                                   debug: "", note: note)
            default:
                // 普通解析；选了本地 AI 但设备忽然不可用时也落到这里
                let r = try QuestionImporter.parseFormattedText(text)
                let preview = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                return LoadOutcome(dtos: r.dtos, skipped: r.skipped.count,
                                   debug: "切出 \(r.blocks) 个题块。识别到的文字开头：\(preview)",
                                   note: mode == .local ? "本地 AI 这次不可用，已用普通解析导入" : "")
            }
        default:
            let data = try Data(contentsOf: url)
            return LoadOutcome(dtos: try QuestionImporter.fromJSON(data),
                               skipped: 0, debug: "", note: "")
        }
    }

    private func insert(_ dtos: [QuestionDTO], deckName: String) {
        // 一次导入 = 一个批次，题库页按这个折叠分组
        let batch = UUID().uuidString
        let now = Date()
        for d in dtos {
            context.insert(Question(stem: d.stem, options: d.options,
                                    answerIndex: d.answerIndex,
                                    explanation: d.explanation, deckName: deckName,
                                    isMulti: d.isMulti, answerIndices: d.answerIndices,
                                    batchID: batch, importedAt: now))
        }
        try? context.save()
    }

    private func loadSample() {
        insert(SampleBank.questions, deckName: "示例题库")
        say("已载入 \(SampleBank.questions.count) 道示例题，可以先跑通全流程")
    }

    private func delete(_ items: [Question], at offsets: IndexSet) {
        for i in offsets { context.delete(items[i]) }
        try? context.save()
    }

    private func clearAll() {
        for q in questions { context.delete(q) }
        try? context.save()
    }

    private func makeExport() {
        func letter(_ i: Int) -> String { letters.indices.contains(i) ? letters[i] : "?" }
        let arr: [[String: Any]] = questions.map { q in
            var item: [String: Any] = ["stem": q.stem,
                                       "options": q.options,
                                       "explanation": q.explanation]
            if q.isMulti {
                item["answers"] = q.answerIndices.sorted().map { letter($0) }
            } else {
                item["answer"] = letter(q.answerIndex)
            }
            return item
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
