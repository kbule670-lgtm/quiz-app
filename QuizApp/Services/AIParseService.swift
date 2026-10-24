import Foundation

// AI 解析导入：把 OCR/提取出的原文按题号切块，每约 8 道题打包发给云端大模型，
// 让它清掉水印页眉广告、区分单选/多选/判断、直接返回结构化题目。
// 三家都是 OpenAI 兼容的 chat/completions 接口，一套客户端通用。
// key 不内置：谁用谁在题库页的设置区填自己的，存本机 UserDefaults。
// 7 版：请求改并发 3 + 分级重试（429/5xx/网络错误才退避重试）；单段最终失败才回退
// 普通解析。统计只按段/块的最终状态记（重试后成功只算 1 个成功段）。

enum AIProvider: String, CaseIterable, Identifiable {
    case deepseek
    case doubao
    case qianwen

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .doubao: return "豆包（方舟）"
        case .qianwen: return "通义千问"
        }
    }

    var baseURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com"
        case .doubao: return "https://ark.cn-beijing.volces.com/api/v3"
        case .qianwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        }
    }

    // DeepSeek 不用填接入点、最省事，所以是默认服务商。
    // 注意：老模型名 deepseek-chat 已被官方下线（2026-07），默认用现行的 deepseek-v4-flash；
    // 三家的模型名都只是默认值，用户在设置里都能改——官方再换代，填新名就能继续用。
    var defaultModel: String {
        switch self {
        case .deepseek: return "deepseek-v4-flash"
        case .doubao: return ""  // 豆包要填自己的接入点 ID（ep- 开头）
        case .qianwen: return "qwen-plus"
        }
    }

    var modelEditable: Bool { true }
    var modelPlaceholder: String {
        self == .doubao ? "填接入点 ID，如 ep-2024…" : defaultModel
    }
}

// 设置读写：都存 UserDefaults，每个服务商各存各的 key 和模型名，切换不丢
enum AISettings {
    private static func keyName(_ provider: AIProvider) -> String { "ai.key.\(provider.rawValue)" }
    private static func modelName(_ provider: AIProvider) -> String { "ai.model.\(provider.rawValue)" }

    static func apiKey(for provider: AIProvider) -> String {
        UserDefaults.standard.string(forKey: keyName(provider)) ?? ""
    }
    static func setApiKey(_ value: String, for provider: AIProvider) {
        UserDefaults.standard.set(value, forKey: keyName(provider))
    }
    static func model(for provider: AIProvider) -> String {
        let saved = UserDefaults.standard.string(forKey: modelName(provider)) ?? ""
        return saved.isEmpty ? provider.defaultModel : saved
    }
    static func setModel(_ value: String, for provider: AIProvider) {
        UserDefaults.standard.set(value, forKey: modelName(provider))
    }
}

enum AIError: LocalizedError {
    case noKey
    case noModel
    case http(Int, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .noKey: return "还没填 API key，先在题库页的「AI 智能解析」设置里填上 key 再导入"
        case .noModel: return "还没填模型名/接入点 ID，先在设置里填好再导入"
        case .http(let code, let body): return "AI 接口返回错误（HTTP \(code)）：\(body.prefix(120))"
        case .badResponse(let msg): return "AI 返回的内容看不懂：\(msg)"
        }
    }
}

// 导入时题目怎么解析，四种方式：
// smart  智能解析（默认）：普通解析先全量跑，只把失败/可疑块交给 AI 修复
// normal 普通解析（本地规则，快、免费，排版野了容易漏题）
// local  本地 AI 全量（苹果端上模型，免费、不用 key、不用联网，整本慢）
// cloud  云端 AI 全量（填自己的 key，最准，按量付费）
enum ImportAIMode: String, CaseIterable, Identifiable {
    case smart
    case normal
    case local
    case cloud

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .smart: return "智能解析"
        case .normal: return "普通解析"
        case .local: return "本地 AI"
        case .cloud: return "云端 AI"
        }
    }
}

// 题目来源：决定完成统计归入「普通解析导入」还是「AI 解析/修复导入」，两类互斥
enum DTOOrigin {
    case rule
    case ai
}

// 带块归属的解析产物：keySuffix 与文件指纹+解析器版本拼成 sourceKey 做续导/去重
struct KeyedDTO {
    var dto: QuestionDTO
    var keySuffix: String   // b<块号> / c<起>-<止> / l<起>-<止> / r<起>-<止> / t<段号> / j<行号>
    var origin: DTOOrigin
}

// 一段云端任务（并发执行器的输入）
struct ChunkJob {
    var text: String
    var blockIndices: [Int]     // 段内块号（硬切段为空）
    var suffix: String          // 段级归属后缀（块数与返回题数对不上时用）
}

// 并发执行器：最多 maxConcurrent 段同时在途；单段可重试错误（429/5xx/网络）退避后
// 最多再试 maxRetries 次；永久错误（4xx 非 429、解码失败、空结果）直接判失败。
// transport 与 sleep 都是可注入接缝：本地回归用假传输模拟 429/超时/5xx 验证重试与统计。
struct ConcurrentChunkRunner {
    var maxConcurrent = 3
    var maxRetries = 2
    var transport: (String) async throws -> [QuestionDTO]
    var sleep: (UInt64) async -> Void = { ns in try? await Task.sleep(nanoseconds: ns) }

    enum FinalState {
        case aiSuccess([KeyedDTO])
        case failed
    }

    func run(jobs: [ChunkJob], progress: @escaping (Int, Int) -> Void) async -> [FinalState] {
        guard !jobs.isEmpty else { return [] }
        var results: [FinalState] = Array(repeating: .failed, count: jobs.count)
        var done = 0
        await withTaskGroup(of: (Int, FinalState).self) { group in
            var next = 0
            let window = min(maxConcurrent, jobs.count)
            while next < window {
                let i = next; next += 1
                group.addTask { (i, await self.runOne(jobs[i])) }
            }
            for await (i, state) in group {
                results[i] = state
                done += 1
                progress(done, jobs.count)
                if next < jobs.count {
                    let j = next; next += 1
                    group.addTask { (j, await self.runOne(jobs[j])) }
                }
            }
        }
        return results
    }

    private func runOne(_ job: ChunkJob) async -> FinalState {
        var attempt = 0
        while true {
            do {
                let dtos = try await transport(job.text)
                guard !dtos.isEmpty else { return .failed }  // 空结果按永久失败，调用方回退
                return .aiSuccess(attribute(dtos, to: job))
            } catch {
                if attempt < maxRetries && Self.isRetryable(error) {
                    await sleep(Self.backoffNanos(error: error, attempt: attempt))
                    attempt += 1
                    continue
                }
                return .failed
            }
        }
    }

    // 归属：返回题数与段内块数恰好相等时逐块归属（续导最细），否则整段共用段后缀
    private func attribute(_ dtos: [QuestionDTO], to job: ChunkJob) -> [KeyedDTO] {
        if !job.blockIndices.isEmpty && dtos.count == job.blockIndices.count {
            return zip(dtos, job.blockIndices).map {
                KeyedDTO(dto: $0.0, keySuffix: "b\($0.1)", origin: .ai)
            }
        }
        return dtos.map { KeyedDTO(dto: $0, keySuffix: job.suffix, origin: .ai) }
    }

    static func isRetryable(_ error: Error) -> Bool {
        if let e = error as? AIError, case .http(let code, _) = e {
            return code == 429 || code >= 500
        }
        if error is URLError { return true }
        return false
    }

    static func backoffNanos(error: Error, attempt: Int) -> UInt64 {
        var base: UInt64 = 1_500_000_000                                 // 一般可重试错误 1.5s 起
        if let e = error as? AIError, case .http(429, _) = e {
            base = 4_000_000_000                                         // 限流退久一点：4s 起
        }
        let scale: UInt64 = attempt == 0 ? 1 : 3                         // 第二次重试 ×3
        return base * scale + UInt64(attempt) * 137_000_000              // 确定性微抖动
    }
}

// 智能模式的修复器选择：本地 AI 可用优先本地；否则用已填好 key 的云端；都没有就不修
enum AIRepairer {
    case local
    case cloud(AIProvider)
    case none

    static func autoSelect(provider: AIProvider) -> AIRepairer {
        if LocalAIParseService.isAvailable { return .local }
        let key = AISettings.apiKey(for: provider)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = AISettings.model(for: provider)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty && !model.isEmpty { return .cloud(provider) }
        return .none
    }

    var displayName: String {
        switch self {
        case .local: return "本地 AI"
        case .cloud(let p): return "云端 AI（\(p.displayName)）"
        case .none: return "无可用 AI"
        }
    }
}

enum AIParseService {

    struct Outcome {
        var keyed: [KeyedDTO] = []
        var skipped: Int = 0            // 最终没救回的块数（按块最终状态记）
        var totalBlocks: Int = 0
        var aiSuccessChunks: Int = 0    // 最终成功的段数（重试后成功只计 1）
        var fallbackChunks: Int = 0     // 最终回退普通解析的段数
        var totalChunks: Int = 0
        var skippedExistingSuffixes: [String] = []  // 命中续导检查点、根本没发的段/块后缀

        var dtos: [QuestionDTO] { keyed.map { $0.dto } }
    }

    struct RepairOutcome {
        var keyed: [KeyedDTO] = []
        var repairedBlocks: [Int] = []
        var failedBlocks: [Int] = []
    }

    // 整份原文走云端 AI：已入库的块/段先按检查点跳过（不花钱），其余并发发；
    // 每段完成即通过 onChunk 交给插入器落盘，闪退最多丢在途的一段。
    static func parse(text: String, provider: AIProvider,
                      existingSuffixes: Set<String> = [],
                      onChunk: (([KeyedDTO]) async -> Void)? = nil,
                      progress: @escaping (Int, Int) -> Void) async throws -> Outcome {
        let (key, model) = try credentials(provider: provider)
        let blocks = QuestionImporter.splitBlocks(text)
        var jobs: [ChunkJob] = []
        var skippedExisting: [String] = []
        if blocks.isEmpty {
            // 切不出题号（格式太野）：按字数硬切，原文整段交给 AI
            var rest = text
            var ti = 0
            while !rest.isEmpty {
                let part = rest.prefix(3000)
                rest = String(rest.dropFirst(part.count))
                let suffix = "t\(ti)"; ti += 1
                if existingSuffixes.contains(suffix) {
                    skippedExisting.append(suffix)
                    continue
                }
                jobs.append(ChunkJob(text: String(part), blockIndices: [], suffix: suffix))
            }
        } else {
            for b in blocks where existingSuffixes.contains("b\(b.index)") {
                skippedExisting.append("b\(b.index)")
            }
            let pending = blocks.filter { !existingSuffixes.contains("b\($0.index)") }
            let per = 8
            for i in stride(from: 0, to: pending.count, by: per) {
                let slice = Array(pending[i..<min(i + per, pending.count)])
                let suffix = "c\(slice.first!.index)-\(slice.last!.index)"
                if existingSuffixes.contains(suffix) {
                    skippedExisting.append(suffix)
                    continue
                }
                jobs.append(ChunkJob(text: slice.map(\.raw).joined(separator: "\n"),
                                     blockIndices: slice.map { $0.index },
                                     suffix: suffix))
            }
        }
        var outcome = Outcome(totalBlocks: blocks.count,
                              totalChunks: jobs.count,
                              skippedExistingSuffixes: skippedExisting)
        guard !jobs.isEmpty else {
            if skippedExisting.isEmpty { throw ImportError.empty }
            return outcome    // 全部命中检查点：没有新活，直接返回
        }
        let runner = ConcurrentChunkRunner(transport: makeTransport(provider: provider,
                                                                    apiKey: key, model: model))
        let states = await runner.run(jobs: jobs, progress: progress)
        for (job, state) in zip(jobs, states) {
            switch state {
            case .aiSuccess(let keyed):
                outcome.aiSuccessChunks += 1
                outcome.keyed += keyed
                if let onChunk { await onChunk(keyed) }
            case .failed:
                outcome.fallbackChunks += 1
                // 回退本地解析器：救回的按规则导入计，救不回的按块计未救回
                if let r = try? QuestionImporter.parseFormattedText(job.text) {
                    let keyed = r.dtos.map {
                        KeyedDTO(dto: $0, keySuffix: job.suffix, origin: .rule)
                    }
                    outcome.keyed += keyed
                    outcome.skipped += r.skipped.count
                    if let onChunk, !keyed.isEmpty { await onChunk(keyed) }
                } else if job.blockIndices.isEmpty {
                    outcome.skipped += 1
                } else {
                    outcome.skipped += job.blockIndices.count
                }
            }
        }
        return outcome
    }

    // 智能模式的云端修复：只发失败/可疑块（每组 ≤4 块），共用同一个并发执行器
    static func repair(blocks: [RawBlock], provider: AIProvider,
                       onChunk: (([KeyedDTO]) async -> Void)? = nil,
                       progress: @escaping (Int, Int) -> Void) async throws -> RepairOutcome {
        let (key, model) = try credentials(provider: provider)
        guard !blocks.isEmpty else { return RepairOutcome() }
        var jobs: [ChunkJob] = []
        for i in stride(from: 0, to: blocks.count, by: 4) {
            let slice = Array(blocks[i..<min(i + 4, blocks.count)])
            jobs.append(ChunkJob(text: slice.map(\.raw).joined(separator: "\n"),
                                 blockIndices: slice.map { $0.index },
                                 suffix: "r\(slice.first!.index)-\(slice.last!.index)"))
        }
        let runner = ConcurrentChunkRunner(transport: makeTransport(provider: provider,
                                                                    apiKey: key, model: model))
        let states = await runner.run(jobs: jobs, progress: progress)
        var result = RepairOutcome()
        for (job, state) in zip(jobs, states) {
            switch state {
            case .aiSuccess(let keyed):
                result.keyed += keyed
                result.repairedBlocks += job.blockIndices
                if let onChunk { await onChunk(keyed) }
            case .failed:
                result.failedBlocks += job.blockIndices
            }
        }
        return result
    }

    private static func credentials(provider: AIProvider) throws -> (key: String, model: String) {
        let key = AISettings.apiKey(for: provider)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIError.noKey }
        let model = AISettings.model(for: provider)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw AIError.noModel }
        return (key, model)
    }

    private static func makeTransport(provider: AIProvider, apiKey: String,
                                      model: String) -> (String) async throws -> [QuestionDTO] {
        { chunk in
            let dtos = try await parseChunk(chunk, provider: provider,
                                            apiKey: apiKey, model: model)
            if dtos.isEmpty { throw AIError.badResponse("这一段没解析出题目") }
            return dtos
        }
    }

    // MARK: - 单段请求（单次尝试；重试由 ConcurrentChunkRunner 统一管）

    private struct ChatRequest: Encodable {
        struct Message: Encodable { var role: String; var content: String }
        var model: String
        var messages: [Message]
        var temperature: Double
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { var content: String }
            var message: Message
        }
        var choices: [Choice]
    }

    private struct AIRaw: Decodable {
        var stem: String
        var options: [String]
        var answer: String
        var type: String?
        var explanation: String?
    }

    // 提示词云端和本地 AI 共用：都要求只回一段严格的题目 JSON
    static func makePrompt(_ chunk: String) -> String {
        """
        你是题库整理助手。下面是从 PDF 里识别出的一段文字，里面混有水印、页眉页脚、广告等杂质，也可能有个别错字。请把其中的题目整理出来。

        要求：
        1. 只输出一个 JSON 数组，不要输出任何其他文字，不要用 markdown 代码块包裹。
        2. 数组每个元素格式：{"stem":"题干","options":["选项一","选项二"],"answer":"A","type":"single"}
        3. type 只能是 single（单选）、multi（多选）、judge（判断）三者之一。
        4. 判断题型：原文有 [题号](单选)/(多选)/(判断) 这类标记的按标记；没有标记时，答案只有一个字母是 single，两个及以上是 multi；选项只有「正确/错误」的是 judge。
        5. 选项最多 5 个（A 到 E），按原文顺序放进 options，不要带 "A." 这样的前缀。
        6. answer 写正确答案的字母：单选和判断写一个（如 "A"），多选连着写（如 "BCDE"）。
        7. 忽略水印（比如斜着压在正文上的"微信小程序：NJFU马院"）、页眉页脚、广告、页码等不是题目的文字；识别错的字按上下文改对。
        8. 原文里没有明确答案的题不要编答案，直接跳过它。

        原文：
        \(chunk)
        """
    }

    private static func parseChunk(_ chunk: String, provider: AIProvider,
                                   apiKey: String, model: String) async throws -> [QuestionDTO] {
        let prompt = makePrompt(chunk)
        guard let url = URL(string: provider.baseURL + "/chat/completions") else {
            throw AIError.badResponse("接口地址不对")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: model,
            messages: [ChatRequest.Message(role: "user", content: prompt)],
            temperature: 0.1))

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw AIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw AIError.badResponse("没有返回内容")
        }
        return try decodeQuestions(from: content)
    }

    // AI 偶尔会给 JSON 外面包一层说明或代码块围栏：只截首个 [ 到末个 ] 之间的部分
    // 云端和本地 AI 共用这条「JSON → DTO」入库管线
    static func decodeQuestions(from content: String) throws -> [QuestionDTO] {
        guard let start = content.firstIndex(of: "["),
              let end = content.lastIndex(of: "]"), start <= end else {
            throw AIError.badResponse("没找到 JSON 数组")
        }
        let json = String(content[start...end])
        guard let data = json.data(using: .utf8) else {
            throw AIError.badResponse("JSON 编码不对")
        }
        let raws = try JSONDecoder().decode([AIRaw].self, from: data)
        // 单道校验不过只跳过那一道，不拖累整段
        return raws.enumerated().compactMap { i, raw in
            try? dto(from: raw, line: i + 1)
        }
    }

    private static func dto(from raw: AIRaw, line: Int) throws -> QuestionDTO {
        var answer = raw.answer.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let type = (raw.type ?? "").lowercased()
        // 判断题答案要是写成文字（正确/错误）而不是字母，翻译一下
        if type == "judge" {
            let isLetters = !answer.isEmpty && answer.allSatisfy { "ABCDE".contains($0) }
            if !isLetters {
                if answer.contains("正确") || answer == "对" || answer == "√" { answer = "A" }
                else if answer.contains("错误") || answer == "错" || answer == "×" { answer = "B" }
            }
        }
        let letters = Array(Set(answer.filter { "ABCDE".contains($0) })).sorted().map { String($0) }
        let explanation = raw.explanation ?? ""
        if type == "judge" {
            // 判断题选项不合规（不是 2 个）时，用标准的 正确/错误 兜底
            let options = raw.options.count == 2 ? raw.options : ["正确", "错误"]
            return try QuestionImporter.dto(stem: raw.stem, options: options,
                                            answerLetter: letters.first ?? "",
                                            explanation: explanation, line: line)
        }
        if type == "multi" || letters.count > 1 {
            return try QuestionImporter.dtoMulti(stem: raw.stem, options: raw.options,
                                                 answerLetters: letters,
                                                 explanation: explanation, line: line)
        }
        return try QuestionImporter.dto(stem: raw.stem, options: raw.options,
                                        answerLetter: letters.first ?? "",
                                        explanation: explanation, line: line)
    }
}
