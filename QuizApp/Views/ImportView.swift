import SwiftUI
import SwiftData
import UniformTypeIdentifiers

private struct Notice: Identifiable {
    let id = UUID()
    let text: String
}

// 增量插入器：一批一落盘。先 insert 再 save，save 成功后才计数并把块视为完成；
// save 失败则把这批对象从 context 摘掉、不计数，块保持未完成（重跑时现查恢复）。
// 去重两层，判定互斥（先检查点、再内容）：
//   第一层 sourceKey（文件指纹+解析器版本+块后缀）——只管同版本续导；
//   第二层 contentHash（题干+选项+答案，归一化白名单见 QuestionImporter）——
//     同一文件指纹内跨版本防重复：解析结果没变的题靠它跳过，解析变了的题作为
//     修正版新入（旧版留在旧批次里，不自动删）。
// 状态只来自数据库实际记录：初始化时从当前题库现查两套集合，不另存检查点文件。
@MainActor
final class IncrementalInserter {
    private let context: ModelContext
    private let fingerprint: String
    private let deckName: String
    private let batch: String
    private let now: Date

    private var knownKeys: Set<String> = []
    private var countByKey: [String: Int] = [:]
    private var knownHashes: Set<String> = []
    private var notedSuffixes: Set<String> = []

    private(set) var ruleInserted = 0
    private(set) var aiInserted = 0
    private(set) var alreadySkipped = 0
    private(set) var saveFailedCount = 0
    // 诊断用：已入库的块号集合（仅 b<号>/b<号>s<分段> 后缀可解析）与新入题按题型分布
    private(set) var insertedBlockNumbers: Set<Int> = []
    private(set) var insertedByType: [String: Int] = [:]

    // 从 sourceKey 后缀解析块号：b12 → 12，b12s1 → 12，其他形式返回 nil
    static func blockNumber(of suffix: String) -> Int? {
        guard suffix.hasPrefix("b") else { return nil }
        let digits = suffix.dropFirst().prefix(while: { $0.isNumber })
        return Int(digits)
    }

    static func typeName(of dto: QuestionDTO) -> String {
        if dto.isMulti { return "多选" }
        if dto.options == ["正确", "错误"] { return "判断" }
        return "单选"
    }

    init(context: ModelContext, questions: [Question], fingerprint: String, deckName: String) {
        self.context = context
        self.fingerprint = fingerprint
        self.deckName = deckName
        self.batch = UUID().uuidString
        self.now = Date()
        for q in questions {
            guard let key = q.sourceKey, key.hasPrefix(fingerprint + "#") else { continue }
            knownKeys.insert(key)
            countByKey[key, default: 0] += 1
            let hash = q.contentHash ?? QuestionImporter.contentHash(
                stem: q.stem, options: q.options,
                answerText: QuestionImporter.answerText(isMulti: q.isMulti,
                                                         answerIndex: q.answerIndex,
                                                         answerIndices: q.answerIndices))
            knownHashes.insert(hash)
        }
    }

    // 本文件、同解析器版本下已有的全部块后缀（服务层据此预跳过，省 AI 调用）
    var existingSuffixes: Set<String> {
        let prefix = "\(fingerprint)#v\(QuestionImporter.parserVersion)#"
        return Set(knownKeys.filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) })
    }

    func isImported(suffix: String) -> Bool {
        knownKeys.contains(QuestionImporter.sourceKey(fingerprint: fingerprint, suffix: suffix))
    }

    // 预跳过的后缀统一在这里计「已存在」（按现存题数计，每个后缀只计一次）
    func noteAlreadySkipped(suffixes: [String]) {
        for suffix in suffixes where !notedSuffixes.contains(suffix) {
            notedSuffixes.insert(suffix)
            let key = QuestionImporter.sourceKey(fingerprint: fingerprint, suffix: suffix)
            alreadySkipped += countByKey[key] ?? 0
            if let n = Self.blockNumber(of: suffix) {
                skippedBlockNumbers.insert(n)
            }
        }
    }

    // 诊断用：内容层/检查点命中的已存在块号（四段归因的入库集需要它）
    private(set) var skippedBlockNumbers: Set<Int> = []

    // 插入一批并立即 save。save 成功才登记键/哈希并计数；失败整批回滚、不计数。
    @discardableResult
    func insert(_ items: [KeyedDTO]) -> Bool {
        var groups: [(suffix: String, items: [KeyedDTO])] = []
        var groupIndex: [String: Int] = [:]
        for item in items {
            if let gi = groupIndex[item.keySuffix] {
                groups[gi].items.append(item)
            } else {
                groupIndex[item.keySuffix] = groups.count
                groups.append((item.keySuffix, [item]))
            }
        }
        var insertedQuestions: [Question] = []
        var pendingRule = 0
        var pendingAI = 0
        var pendingHashes: [String] = []
        var pendingKeys: [String] = []
        var pendingKeyCounts: [String: Int] = [:]  // 本批每键实际入几道，save 成功后并入 countByKey
        var pendingBlockNumbers: Set<Int> = []
        var pendingByType: [String: Int] = [:]
        for group in groups {
            let key = QuestionImporter.sourceKey(fingerprint: fingerprint, suffix: group.suffix)
            if knownKeys.contains(key) {
                noteAlreadySkipped(suffixes: [group.suffix])
                continue
            }
            var groupInserted = false
            for item in group.items {
                let hash = QuestionImporter.contentHash(for: item.dto)
                if knownHashes.contains(hash) || pendingHashes.contains(hash) {
                    alreadySkipped += 1  // 内容层命中：同一文件里这道题已存在
                    if let n = Self.blockNumber(of: group.suffix) {
                        skippedBlockNumbers.insert(n)
                    }
                    continue
                }
                let q = Question(stem: item.dto.stem, options: item.dto.options,
                                 answerIndex: item.dto.answerIndex,
                                 explanation: item.dto.explanation, deckName: deckName,
                                 isMulti: item.dto.isMulti,
                                 answerIndices: item.dto.answerIndices,
                                 batchID: batch, importedAt: now,
                                 sourceKey: key, contentHash: hash)
                context.insert(q)
                insertedQuestions.append(q)
                pendingHashes.append(hash)
                pendingKeyCounts[key, default: 0] += 1
                if item.origin == .ai { pendingAI += 1 } else { pendingRule += 1 }
                if let n = Self.blockNumber(of: group.suffix) {
                    pendingBlockNumbers.insert(n)
                }
                pendingByType[Self.typeName(of: item.dto), default: 0] += 1
                groupInserted = true
            }
            if groupInserted { pendingKeys.append(key) }
        }
        guard !insertedQuestions.isEmpty else { return true }
        do {
            try context.save()
        } catch {
            for q in insertedQuestions { context.delete(q) }
            saveFailedCount += insertedQuestions.count
            return false
        }
        // save 成功后才登记键/哈希/计数（7.ipa 口径：保存失败不计数）
        for k in pendingKeys { knownKeys.insert(k) }
        for h in pendingHashes { knownHashes.insert(h) }
        for (k, c) in pendingKeyCounts { countByKey[k, default: 0] += c }
        ruleInserted += pendingRule
        aiInserted += pendingAI
        insertedBlockNumbers.formUnion(pendingBlockNumbers)
        for (t, c) in pendingByType { insertedByType[t, default: 0] += c }
        return true
    }
}

// 题库页：导入（PDF/Word/JSON/CSV/txt，四种解析方式）/ 搜索 / 按批次折叠分组 /
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
    // 8.ipa 诊断状态：最近一次导入的诊断、已保存 OCR 原文与行（重算用，只读不写库）
    @State private var lastDiagnostics: ImportDiagnostics?
    @State private var lastOCRText: String?
    @State private var lastOCRLines: [OCRLine]?
    @State private var lastFingerprint: String?
    @State private var recomputeText: String?
    @State private var diagnosticsURL: URL?
    @State private var batchPendingDelete: Batch?
    @State private var showDeleteBatchConfirm = false
    @State private var searchText = ""
    @State private var expandedBatches: Set<String> = []

    // 解析方式：智能解析（默认）/ 普通解析 / 本地 AI / 云端 AI（存 AppStorage）
    @AppStorage("ai.mode") private var modeRaw = ImportAIMode.smart.rawValue
    @AppStorage("ai.provider") private var providerRaw = AIProvider.deepseek.rawValue
    @State private var aiKeyText = ""
    @State private var aiModelText = ""

    private var aiMode: ImportAIMode { ImportAIMode(rawValue: modeRaw) ?? .smart }
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
                // 8.ipa 导入诊断：四段计数 + 三组清理对照（重算只读已保存原文，不写题库）
                if let diag = lastDiagnostics {
                    Section("导入诊断") {
                        Text(diag.reportText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let w = diag.gapWarning {
                            Text("⚠️ \(w)")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                        Button("重算：三组清理对照（不写入题库）") { runRecompute() }
                        if let rt = recomputeText {
                            Text(rt)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("生成诊断报告文件") { shareDiagnostics() }
                        if let url = diagnosticsURL {
                            ShareLink("分享诊断报告", item: url)
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
            .confirmationDialog("删除该批次？",
                                isPresented: $showDeleteBatchConfirm,
                                titleVisibility: .visible) {
                if let batch = batchPendingDelete {
                    Button("删除「\(batch.title)」共 \(batch.items.count) 道",
                           role: .destructive) { deleteBatch(batch) }
                }
                Button("取消", role: .cancel) { batchPendingDelete = nil }
            } message: {
                Text("只删除该批次的题目，不影响其他批次。这个操作不能撤销。")
            }
            .onAppear {
                // 第一次打开：默认智能解析（普通解析打底 + AI 只修疑难题，两边设备都适用）
                if UserDefaults.standard.object(forKey: "ai.mode") == nil {
                    modeRaw = ImportAIMode.smart.rawValue
                }
                reloadAIFields()
            }
            .onChange(of: providerRaw) { _ in reloadAIFields() }
        }
    }

    private var importButtonTitle: String {
        switch aiMode {
        case .smart: return "从文件导入题库（智能解析）"
        case .local: return "从文件导入题库（本地 AI 解析）"
        case .cloud: return "从文件导入题库（云端 AI 解析）"
        case .normal: return "从文件导入题库（PDF / Word / JSON / CSV / txt）"
        }
    }

    // 文件夹式小条：文件名 + 题数 + 展开箭头，默认折叠，点一下展开/收起；
    // 8.ipa：行尾加按批次删除入口（展示批次名与实际题数、二次确认）。
    private func batchHeader(_ batch: Batch) -> some View {
        HStack(spacing: 8) {
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
            Button {
                batchPendingDelete = batch
                showDeleteBatchConfirm = true
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
    }

    // 按批次删除：只按本批记录 ID 删（batchID 归属；legacy 组按题库名＋无批次匹配），
    // 一次事务保存、失败回滚不计数；绝不按内容哈希删——内容相同的题在不同批次是独立记录。
    private func deleteBatch(_ batch: Batch) {
        let targets: [Question]
        if batch.id.hasPrefix("legacy-") {
            targets = questions.filter { $0.batchID == nil && $0.deckName == batch.title }
        } else {
            targets = questions.filter { $0.batchID == batch.id }
        }
        for q in targets { context.delete(q) }
        do {
            try context.save()
        } catch {
            context.rollback()
            say("删除失败，已回滚：\(error.localizedDescription)")
        }
        batchPendingDelete = nil
    }

    // 三组清理对照：用本次导入已保存的 OCR 原文重跑清理→切题→计数（只产出诊断计数，
    // 绝不写题库）。三组同一份原文；有坐标时新规则走真实位置规则。
    // 固定格式对照表（本地模拟与装机实测统一口径）。
    // 重算用本次导入已保存的 OCR 原文（@State，会话级）。
    // 数据层上原文＋行坐标已持久化在磁盘存档里（带清理器版本标记），
    // 未来清理器升级可直接读存档重跑，无需重新识别——见 DocumentImporter.archivedText。
    private func runRecompute() {
        guard let text = lastOCRText else { return }
        recomputeText = "正在重算…"
        Task {
            let legacy = ImportRecompute.run(ocrText: text, rule: .legacy7)
            let noShort = ImportRecompute.run(ocrText: text, rule: .legacyNoShortRepeat)
            let meta: RecomputeResult
            if let lines = lastOCRLines, !lines.isEmpty {
                let totalPages = (lines.map(\.page).max() ?? 0) + 1
                meta = ImportRecompute.runWithLines(lines, totalPages: totalPages, rule: .meta8)
            } else {
                meta = ImportRecompute.run(ocrText: text, rule: .meta8)
            }
            let table = [
                "【三组清理对照（同一份已保存 OCR 原文，重算不写入题库）】",
                "指标｜原清理规则｜关闭重复短行删除｜新清理规则",
                "判断题解析成功数｜\(legacy.judgeSuccess)｜\(noShort.judgeSuccess)｜\(meta.judgeSuccess)",
                "多选题解析成功数｜\(legacy.multiSuccess)｜\(noShort.multiSuccess)｜\(meta.multiSuccess)",
                "「正确」行删除数｜\(legacy.correctDeleted)｜0｜\(meta.correctDeleted)",
                "「错误」行删除数｜\(legacy.wrongDeleted)｜0｜\(meta.wrongDeleted)",
                "异常块数｜\(legacy.abnormalBlocks)｜\(noShort.abnormalBlocks)｜\(meta.abnormalBlocks)",
                "实际可入库题数｜\(legacy.insertableCount)｜\(noShort.insertableCount)（仅模拟，不写入）｜\(meta.insertableCount)",
                "注：判断题恢复后请单独看多选题是否恢复，不得默认随之恢复。",
            ].joined(separator: "\n")
            recomputeText = table
        }
    }

    // 诊断报告导出：只含计数、分布、失败原因，不含完整题目内容。
    // 文件名带文件指纹前 8 位，便于和磁盘上的 OCR 存档对应上。
    private func shareDiagnostics() {
        guard let diag = lastDiagnostics else { return }
        let suffix = lastFingerprint.map { String($0.prefix(8)) } ?? "unknown"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quiz-import-diagnostics-\(suffix).txt")
        do {
            try diag.reportText.write(to: url, atomically: true, encoding: .utf8)
            diagnosticsURL = url
        } catch {
            say("诊断报告生成失败：\(error.localizedDescription)")
        }
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

    // MARK: - 解析方式区（智能 / 普通 / 本地 AI / 云端 AI 四选一）

    private var modeSection: some View {
        Section {
            Picker("解析方式", selection: $modeRaw) {
                Text("智能解析").tag(ImportAIMode.smart.rawValue)
                Text("普通解析").tag(ImportAIMode.normal.rawValue)
                if LocalAIParseService.isAvailable {
                    Text("本地 AI").tag(ImportAIMode.local.rawValue)
                }
                Text("云端 AI").tag(ImportAIMode.cloud.rawValue)
            }
            .pickerStyle(.segmented)
            switch aiMode {
            case .smart:
                Text("推荐：先用普通解析秒速处理绝大部分题，只有解析失败或可疑的少数题才交给 AI 修复（有本地 AI 用本地的，没有就用填了 key 的云端，都没有就如实报告剩余数量）。最快、最省，也最不容易丢题。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            Text("导入流程：选文件 → 自动识别文字 → 按选的方式解析 → 题目分批直接入库（中途退出也不会丢已入库的），完成时按「普通解析 / AI / 已存在 / 未救回」四类报数。")
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

    private struct ImportStats {
        var unrecovered = 0     // 最终没救回的块数
        var notes: [String] = []
        var debug = ""          // 失败时给用户看的诊断（切出几个题块、文字长什么样）
        var diagnostics: ImportDiagnostics?
        var savedOCRText: String?       // 本次导入的 OCR/文字层原文（重算与对照实验用）
        var savedOCRLines: [OCRLine]?   // 带坐标的 OCR 行（有坐标时重算走真实位置规则）
        var fingerprint: String?
        var isOCR = false
        var pdfPagesTotal = 0
        // 四段归因用集合，统一为题号空间（ParsedItem.number；块序号是另一套编号，绝不混用）
        // 仅普通/智能模式的块后缀路径可精确归因；云端/本地模式留空
        var markerNumbers: Set<Int> = []
        var blockNumbers: Set<Int> = []
        var parsedNumbers: Set<Int> = []
        // 模式内解析结果的题型分布与异常块数（诊断 C 段）
        var modeBlocksByType: [String: Int] = [:]
        var modeAbnormal = 0
    }

    // 题号四段归因：OCR 标记集 → 题块集 → 校验通过集 → 入库集，四次差集。
    // a. OCR 中未发现题号候选：期望范围（连续编号）内、标记集里没有的号；
    // b. 发现题号但未切成有效题块：标记集有、题块集没有；
    // c. 已切成题块但校验失败或未救回：题块集有、校验通过集没有；
    // d. 已入库或内容重复跳过：入库集本身，不列缺失（入库数在 D 段）。
    // 仅编号连续的资料给确定性清单；否则只作疑似提示。
    private static func stageAttribution(markerNumbers: Set<Int>,
                                         blockNumbers: Set<Int>,
                                         parsedNumbers: Set<Int>,
                                         insertedNumbers: Set<Int>)
        -> (stages: [(stage: String, numbers: [Int])], continuous: Bool) {
        let all = markerNumbers.union(blockNumbers).union(parsedNumbers)
        let sorted = all.sorted()
        var continuous = false
        if let first = sorted.first, let last = sorted.last, sorted.count >= 10 {
            let gaps = (last - first + 1) - sorted.count
            continuous = gaps <= max(5, sorted.count / 10)
        }
        let expected: Set<Int>
        if continuous, let first = sorted.first, let last = sorted.last {
            expected = Set(first...last)
        } else {
            expected = all
        }
        let a = expected.subtracting(markerNumbers).sorted()
        let b = markerNumbers.subtracting(blockNumbers).sorted()
        let c = blockNumbers.subtracting(parsedNumbers).sorted()
        // 第 4 段不是缺失：已入库或因内容重复跳过的号（四次差集的终点，用来闭环对账）
        let d = insertedNumbers.intersection(expected).sorted()
        return ([("OCR 中未发现题号候选", a),
                 ("发现题号但未切成有效题块", b),
                 ("已切成题块但校验失败或未救回", c),
                 ("已入库或内容重复跳过（非缺失）", d)],
                continuous)
    }

    // 诊断用：文本里 A–E 选项标记的个数（分隔符形式）
    private static func countOptionMarkers(in text: String) -> Int {
        guard let re = try? NSRegularExpression(pattern: #"([ABCDE])[ \t]*[.、．:：]"#) else {
            return 0
        }
        return re.numberOfMatches(in: text,
                                  range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func typeName(of dto: QuestionDTO) -> String {
        if dto.isMulti { return "多选" }
        if dto.options == ["正确", "错误"] { return "判断" }
        return "单选"
    }

    private func handleImportURL(_ url: URL) {
        let deckName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()
        if ext == "doc" {
            say("老版 .doc 读不了，在 Word/WPS 里另存为 .docx 再导一次")
            return
        }
        let textKinds = ["pdf", "docx", "txt"]
        // 云端 AI 全量 + 文字类文件：先查 key 和模型名，没填就别白跑一遍 OCR
        if aiMode == .cloud && textKinds.contains(ext) {
            if AISettings.apiKey(for: provider)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                say("你选了云端 AI 解析，但还没填 API key。先在题库页顶上把 key 填上再导入，或者换成智能解析 / 普通解析。")
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
        // 8.ipa：导入期间屏幕常亮，任务结束（成功/失败/取消）时恢复
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = true }
        Task {
            // asCopy 复制来的文件在临时目录，一般不用权限；保险起见试一下，有就用完释放
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            defer { DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = false } }
            do {
                let data = try Data(contentsOf: url)
                let fingerprint = QuestionImporter.sha256Hex(data)
                // 插入器从数据库实际记录现查去重集合（不依赖任何缓存的检查点）
                let inserter = IncrementalInserter(context: context, questions: questions,
                                                   fingerprint: fingerprint, deckName: deckName)
                let stats = try await Self.load(data: data, ext: ext, mode: mode,
                                                provider: currentProvider,
                                                inserter: inserter,
                                                fingerprint: fingerprint) { status in
                    DispatchQueue.main.async { importStatus = status }
                }
                importStatus = nil
                // 诊断状态（供诊断区与重算用；重算只读已保存原文，不写题库）
                lastDiagnostics = stats.diagnostics
                lastOCRText = stats.savedOCRText
                lastOCRLines = stats.savedOCRLines
                lastFingerprint = stats.fingerprint
                recomputeText = nil
                diagnosticsURL = nil
                let newCount = inserter.ruleInserted + inserter.aiInserted
                if newCount == 0 && inserter.alreadySkipped == 0 {
                    var msg = "文件里没有读到题目"
                    if stats.unrecovered > 0 {
                        msg += "\n有 \(stats.unrecovered) 块内容没能解析出来"
                    }
                    if !stats.debug.isEmpty { msg += "\n" + stats.debug }
                    say(msg)
                    return
                }
                // 入库完成：存档页 stage 推进到 inserted（逐页原子写；失败的页保持原 stage）
                if ext == "pdf" {
                    DocumentImporter.markArchiveStage(fingerprint: fingerprint,
                                                      pageCount: stats.pdfPagesTotal,
                                                      stage: .inserted)
                }
                // 四分统计，互斥对账：新入（普通/AI）+ 已存在跳过 + 未救回
                var lines = ["导入完成",
                             "普通解析新入 \(inserter.ruleInserted) 道 · AI 新入 \(inserter.aiInserted) 道"]
                if inserter.alreadySkipped > 0 {
                    lines.append("已存在跳过 \(inserter.alreadySkipped) 道（同一文件之前导过，没重复入库）")
                }
                if stats.unrecovered > 0 {
                    lines.append("未救回 \(stats.unrecovered) 块（解析不出来、AI 也没修好）")
                }
                if inserter.saveFailedCount > 0 {
                    lines.append("另有 \(inserter.saveFailedCount) 道保存失败，下次导入同一文件会自动补上")
                }
                lines.append(contentsOf: stats.notes)
                if let w = stats.diagnostics?.gapWarning {
                    lines.append("⚠️ \(w)，诊断区有各阶段计数")
                }
                say(lines.joined(separator: "\n"))
            } catch {
                importStatus = nil
                say("导入失败：\(error.localizedDescription)")
            }
        }
    }

    // 实际读文件+解析+分批入库。PDF 图片版会先逐页 OCR（慢，放后台跑）。
    // 8.ipa：全程产出导入诊断（OCR → 清理 → 切题 → 入库四段计数）。
    private static func load(data: Data, ext: String, mode: ImportAIMode,
                             provider: AIProvider, inserter: IncrementalInserter,
                             fingerprint: String,
                             status: @escaping (String) -> Void) async throws -> ImportStats {
        switch ext {
        case "csv":
            let text = String(data: data, encoding: .utf8) ?? ""
            let dtos = try QuestionImporter.fromCSV(text)
            await insertBatched(dtos.enumerated().map {
                KeyedDTO(dto: $0.element, keySuffix: "j\($0.offset)", origin: .rule)
            }, inserter: inserter)
            return ImportStats()
        case "pdf", "docx", "txt":
            let text: String
            var stats = ImportStats()
            stats.fingerprint = fingerprint
            var diag = ImportDiagnostics()
            if ext == "pdf" {
                let r = try await DocumentImporter.pdfTextDetailed(
                    data, fingerprint: fingerprint) { cur, total in
                    status("这份 PDF 是图片版的，正在逐页识别文字：第 \(cur)/\(total) 页，耐心等一下")
                }
                text = r.text
                stats.savedOCRText = r.rawText
                stats.savedOCRLines = r.rawLines
                stats.isOCR = r.isOCR
                stats.pdfPagesTotal = r.pagesTotal
                stats.markerNumbers = QuestionImporter.markerNumbers(in: r.rawText)
                diag.ocrPagesDone = r.pagesDone
                diag.ocrPagesTotal = r.pagesTotal
                diag.blankPages = r.blankPages
                diag.ocrTotalChars = r.rawText.count
                diag.ocrMarkerCandidates = r.cleanup.markersBefore
                diag.ocrOptionMarkers = countOptionMarkers(in: r.rawText)
                diag.ocrJudgeCorrectLines = r.rawLines.filter {
                    $0.text.trimmingCharacters(in: .whitespaces) == "正确"
                }.count
                diag.ocrJudgeWrongLines = r.rawLines.filter {
                    $0.text.trimmingCharacters(in: .whitespaces) == "错误"
                }.count
                diag.cleanup = r.cleanup
            } else if ext == "docx" {
                text = try DocumentImporter.docxText(data)
                stats.savedOCRText = text
                stats.markerNumbers = QuestionImporter.markerNumbers(in: text)
                diag.ocrTotalChars = text.count
                diag.ocrMarkerCandidates = QuestionImporter.markerCount(in: text)
                diag.ocrOptionMarkers = countOptionMarkers(in: text)
            } else {
                text = String(data: data, encoding: .utf8) ?? ""
                stats.savedOCRText = text
                stats.markerNumbers = QuestionImporter.markerNumbers(in: text)
                diag.ocrTotalChars = text.count
                diag.ocrMarkerCandidates = QuestionImporter.markerCount(in: text)
                diag.ocrOptionMarkers = countOptionMarkers(in: text)
            }
            // C 段切题事实（与各模式内部分别算的解析结果口径一致）
            let blocks = QuestionImporter.splitBlocks(text)
            diag.splitCandidates = QuestionImporter.markerCount(in: text)
            diag.splitBlocks = blocks.count
            diag.lowConfidenceBlocks = blocks.filter { $0.score < 8 }.count
            diag.unblockedChars = max(0, text.count - blocks.reduce(0) { $0 + $1.raw.count })
            stats.blockNumbers = Set(blocks.compactMap(\.number))
            var modeStats: ImportStats
            switch mode {
            case .cloud:
                modeStats = try await loadCloud(text: text, provider: provider,
                                                inserter: inserter, status: status)
            case .local where LocalAIParseService.isAvailable:
                modeStats = try await loadLocal(text: text, inserter: inserter, status: status)
            case .smart:
                modeStats = await loadSmart(text: text, provider: provider,
                                            inserter: inserter, status: status)
            default:
                // 普通解析；选了本地 AI 但设备忽然不可用时也落到这里
                modeStats = await loadNormal(text: text, inserter: inserter, mode: mode)
            }
            stats.unrecovered = modeStats.unrecovered
            stats.notes = modeStats.notes
            stats.debug = modeStats.debug
            stats.parsedNumbers = modeStats.parsedNumbers
            diag.blocksByType = modeStats.modeBlocksByType
            diag.abnormalBlocks = modeStats.modeAbnormal
            // D 段：插入器计数（save 成功后才计数，口径与完成提示一致）
            diag.insertedRule = await inserter.ruleInserted
            diag.insertedAI = await inserter.aiInserted
            diag.skippedExisting = await inserter.alreadySkipped
            diag.unrecovered = stats.unrecovered
            diag.insertedByType = await inserter.insertedByType
            // 四段归因（仅普通/智能模式的块后缀路径可精确归因；云端/本地模式只给计数）
            if !modeStats.parsedNumbers.isEmpty {
                // 插入器记的是块序号，经 load() 的块表映射回题号（split 第二部分
                // 的后缀 b<父块号>s1 会映射到父块题号，集合去重后不影响对账）
                let ordinalToNumber = Dictionary(
                    uniqueKeysWithValues: blocks.enumerated().compactMap { i, b in
                        b.number.map { (i, $0) }
                    })
                let insertedOrdinals = await inserter.insertedBlockNumbers
                    .union(await inserter.skippedBlockNumbers)
                let insertedNumbers = insertedOrdinals.compactMap { ordinalToNumber[$0] }
                    .reduce(into: Set<Int>()) { $0.insert($1) }
                let (stages, continuous) = stageAttribution(
                    markerNumbers: stats.markerNumbers,
                    blockNumbers: stats.blockNumbers,
                    parsedNumbers: modeStats.parsedNumbers,
                    insertedNumbers: insertedNumbers)
                diag.missingByStage = stages
                diag.numbersContinuous = continuous
            }
            stats.diagnostics = diag
            return stats
        default:
            let dtos = try QuestionImporter.fromJSON(data)
            await insertBatched(dtos.enumerated().map {
                KeyedDTO(dto: $0.element, keySuffix: "j\($0.offset)", origin: .rule)
            }, inserter: inserter)
            return ImportStats()
        }
    }

    // 每约 40 道一批落盘（仅用于逐题后缀互不相同的路径：普通/智能主流程、JSON、CSV）
    private static func insertBatched(_ items: [KeyedDTO], inserter: IncrementalInserter) async {
        let size = 40
        guard items.count > size else {
            if !items.isEmpty { await inserter.insert(items) }
            return
        }
        for i in stride(from: 0, to: items.count, by: size) {
            await inserter.insert(Array(items[i..<min(i + size, items.count)]))
        }
    }

    private static func loadNormal(text: String, inserter: IncrementalInserter,
                                   mode: ImportAIMode) async -> ImportStats {
        let r = QuestionImporter.parseDetailed(text)
        var stats = ImportStats()
        var pending: [KeyedDTO] = []
        for item in r.items {
            let suffix = QuestionImporter.keySuffix(for: item)
            if await inserter.isImported(suffix: suffix) {
                await inserter.noteAlreadySkipped(suffixes: [suffix])
                continue
            }
            pending.append(KeyedDTO(dto: item.dto, keySuffix: suffix, origin: .rule))
        }
        await insertBatched(pending, inserter: inserter)
        var unrecovered = 0
        for sk in r.skipped {
            let suffix = "b\(sk.index)"
            if await inserter.isImported(suffix: suffix) {
                await inserter.noteAlreadySkipped(suffixes: [suffix])
            } else {
                unrecovered += 1
            }
        }
        stats.unrecovered = unrecovered
        stats.parsedNumbers = Set(r.items.compactMap(\.number))
        stats.modeBlocksByType = Dictionary(
            grouping: r.items, by: { IncrementalInserter.typeName(of: $0.dto) })
            .mapValues(\.count)
        stats.modeAbnormal = r.skipped.count + r.items.filter(\.suspect).count
        let preview = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        stats.debug = "切出 \(r.blocks.count) 个题块。识别到的文字开头：\(preview)"
        if mode == .local {
            stats.notes.append("本地 AI 这次不可用，已用普通解析导入")
        }
        return stats
    }

    private static func loadCloud(text: String, provider: AIProvider,
                                  inserter: IncrementalInserter,
                                  status: @escaping (String) -> Void) async throws -> ImportStats {
        let suffixes = await inserter.existingSuffixes
        let outcome = try await AIParseService.parse(
            text: text, provider: provider, existingSuffixes: suffixes,
            onChunk: { keyed in await inserter.insert(keyed) },
            progress: { cur, total in status("云端 AI 解析中 第 \(cur)/\(total) 段") })
        await inserter.noteAlreadySkipped(suffixes: outcome.skippedExistingSuffixes)
        var stats = ImportStats()
        stats.unrecovered = outcome.skipped
        stats.modeBlocksByType = Dictionary(
            grouping: outcome.keyed, by: { IncrementalInserter.typeName(of: $0.dto) })
            .mapValues(\.count)
        stats.modeAbnormal = outcome.skipped
        if outcome.totalChunks > 0 {
            stats.notes.append("云端 AI 成功 \(outcome.aiSuccessChunks)/\(outcome.totalChunks) 段"
                + (outcome.fallbackChunks > 0 ? "，\(outcome.fallbackChunks) 段回退了普通解析" : ""))
        }
        return stats
    }

    private static func loadLocal(text: String, inserter: IncrementalInserter,
                                  status: @escaping (String) -> Void) async throws -> ImportStats {
        let suffixes = await inserter.existingSuffixes
        let outcome = try await LocalAIParseService.parse(
            text: text, existingSuffixes: suffixes,
            onChunk: { keyed in await inserter.insert(keyed) },
            progress: { cur, total in status("本地 AI 解析中 第 \(cur)/\(total) 段") })
        await inserter.noteAlreadySkipped(suffixes: outcome.skippedExistingSuffixes)
        var stats = ImportStats()
        stats.unrecovered = outcome.skipped
        stats.modeBlocksByType = Dictionary(
            grouping: outcome.keyed, by: { IncrementalInserter.typeName(of: $0.dto) })
            .mapValues(\.count)
        stats.modeAbnormal = outcome.skipped
        if outcome.totalChunks > 0 {
            stats.notes.append("本地 AI 成功 \(outcome.aiSuccessChunks)/\(outcome.totalChunks) 段"
                + (outcome.fallbackChunks > 0 ? "，\(outcome.fallbackChunks) 段回退了普通解析" : ""))
        }
        return stats
    }

    // 智能解析：普通解析全量先行 → 失败块/可疑块进 AI 修复队列 → 修不好如实计数
    private static func loadSmart(text: String, provider: AIProvider,
                                  inserter: IncrementalInserter,
                                  status: @escaping (String) -> Void) async -> ImportStats {
        var stats = ImportStats()
        let r = QuestionImporter.parseDetailed(text)
        let byIndex = Dictionary(uniqueKeysWithValues: r.blocks.map { ($0.index, $0) })

        // 第一阶段：普通解析。正常题分批入库；可疑题先扣下等 AI 复核
        var pending: [KeyedDTO] = []
        var suspectItems: [ParsedItem] = []
        for item in r.items {
            let suffix = QuestionImporter.keySuffix(for: item)
            if await inserter.isImported(suffix: suffix) {
                await inserter.noteAlreadySkipped(suffixes: [suffix])
                continue
            }
            if item.suspect {
                suspectItems.append(item)
            } else {
                pending.append(KeyedDTO(dto: item.dto, keySuffix: suffix, origin: .rule))
            }
        }
        await insertBatched(pending, inserter: inserter)
        stats.parsedNumbers = Set(r.items.compactMap(\.number))
        stats.modeBlocksByType = Dictionary(
            grouping: r.items, by: { IncrementalInserter.typeName(of: $0.dto) })
            .mapValues(\.count)
        stats.modeAbnormal = r.skipped.count + r.items.filter(\.suspect).count
        status("普通解析完成：新入 \(await inserter.ruleInserted) 道，正在处理疑难题…")

        // 修复队列：解析失败块 + 可疑块（已被检查点命中的不进队列）
        var skippedQueue: [RawBlock] = []
        var unrecovered = 0
        for sk in r.skipped {
            let suffix = "b\(sk.index)"
            if await inserter.isImported(suffix: suffix) {
                await inserter.noteAlreadySkipped(suffixes: [suffix])
            } else if let block = byIndex[sk.index] {
                skippedQueue.append(block)
            } else {
                unrecovered += 1
            }
        }
        var suspectQueue: [(item: ParsedItem, block: RawBlock)] = []
        for item in suspectItems {
            if let block = byIndex[item.blockIndex] {
                suspectQueue.append((item, block))
            }
        }
        let queueCount = skippedQueue.count + suspectQueue.count
        guard queueCount > 0 else {
            stats.unrecovered = unrecovered
            return stats
        }

        let repairer = AIRepairer.autoSelect(provider: provider)
        stats.notes.append("智能解析：\(queueCount) 块疑难题交给 \(repairer.displayName) 修复")
        switch repairer {
        case .none:
            unrecovered += skippedQueue.count
            if !suspectQueue.isEmpty {
                await insertBatched(suspectQueue.map {
                    KeyedDTO(dto: $0.item.dto,
                             keySuffix: QuestionImporter.keySuffix(for: $0.item), origin: .rule)
                }, inserter: inserter)
                stats.notes.append("没有可用的 AI 修复，\(suspectQueue.count) 道可疑题已按普通解析结果原样入库")
            }
        case .local, .cloud:
            let blocks = skippedQueue + suspectQueue.map { $0.block }
            var failed = Set(blocks.map { $0.index })
            var repairedCount = 0
            do {
                let outcome: AIParseService.RepairOutcome
                if case .local = repairer {
                    outcome = try await LocalAIParseService.repair(
                        blocks: blocks,
                        onChunk: { keyed in await inserter.insert(keyed) },
                        progress: { cur, total in status("AI 修复中（本地 AI）第 \(cur)/\(total) 块") })
                } else {
                    outcome = try await AIParseService.repair(
                        blocks: blocks, provider: provider,
                        onChunk: { keyed in await inserter.insert(keyed) },
                        progress: { cur, total in status("AI 修复中（云端）第 \(cur)/\(total) 组") })
                }
                failed = Set(outcome.failedBlocks)
                repairedCount = outcome.repairedBlocks.count
            } catch {
                stats.notes.append("AI 修复没跑起来：\(error.localizedDescription)")
            }
            unrecovered += skippedQueue.filter { failed.contains($0.index) }.count
            // 可疑块修失败的回退普通解析结果入库（已通过校验，别丢）
            let fallenSuspects = suspectQueue.filter { failed.contains($0.item.blockIndex) }
            if !fallenSuspects.isEmpty {
                await insertBatched(fallenSuspects.map {
                    KeyedDTO(dto: $0.item.dto,
                             keySuffix: QuestionImporter.keySuffix(for: $0.item), origin: .rule)
                }, inserter: inserter)
                stats.notes.append("\(fallenSuspects.count) 道可疑题 AI 没修成，已按普通解析结果入库")
            }
            if repairedCount > 0 {
                stats.notes.append("AI 成功修复 \(repairedCount) 块")
            }
        }
        stats.unrecovered = unrecovered
        return stats
    }

    private func loadSample() {
        // 一次导入 = 一个批次，题库页按这个折叠分组
        let batch = UUID().uuidString
        let now = Date()
        for d in SampleBank.questions {
            context.insert(Question(stem: d.stem, options: d.options,
                                    answerIndex: d.answerIndex,
                                    explanation: d.explanation, deckName: "示例题库",
                                    isMulti: d.isMulti, answerIndices: d.answerIndices,
                                    batchID: batch, importedAt: now))
        }
        try? context.save()
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
