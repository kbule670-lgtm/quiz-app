import Foundation

// AI 解析导入：把 OCR/提取出的原文按题号切块，每约 8 道题打包发给云端大模型，
// 让它清掉水印页眉广告、区分单选/多选/判断、直接返回结构化题目。
// 三家都是 OpenAI 兼容的 chat/completions 接口，一套客户端通用。
// key 不内置：谁用谁在题库页的设置区填自己的，存本机 UserDefaults。

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

    // DeepSeek 模型名固定、不用填接入点，最省事，所以是默认
    var defaultModel: String {
        switch self {
        case .deepseek: return "deepseek-chat"
        case .doubao: return ""  // 豆包要填自己的接入点 ID（ep- 开头）
        case .qianwen: return "qwen-plus"
        }
    }

    var modelEditable: Bool { self != .deepseek }
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

enum AIParseService {

    struct Outcome {
        var dtos: [QuestionDTO]
        var skipped: Int       // 两条路都没救回来的题数
        var totalBlocks: Int
        var fallbackChunks: Int // 回退本地解析的段数
        var totalChunks: Int
    }

    // 整份原文走 AI：逐段发，某段 AI 挂了就自动用本地解析器解析那一段，不中断整体
    static func parse(text: String, provider: AIProvider,
                      progress: @escaping (Int, Int) -> Void) async throws -> Outcome {
        let key = AISettings.apiKey(for: provider)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIError.noKey }
        let model = AISettings.model(for: provider)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw AIError.noModel }

        // 按题号切块再打包；切不出题号（格式太野）就按字数硬切，原文整段交给 AI
        let blocks = QuestionImporter.splitBlocks(text)
        var chunks: [String] = []
        if blocks.isEmpty {
            var rest = text[...]
            while !rest.isEmpty {
                let part = rest.prefix(3000)
                chunks.append(String(part))
                rest = rest.dropFirst(part.count)
            }
        } else {
            let per = 8
            for i in stride(from: 0, to: blocks.count, by: per) {
                let slice = blocks[i..<min(i + per, blocks.count)]
                chunks.append(slice.map(\.raw).joined(separator: "\n"))
            }
        }
        guard !chunks.isEmpty else { throw ImportError.empty }

        var outcome = Outcome(dtos: [], skipped: 0,
                              totalBlocks: blocks.count,
                              fallbackChunks: 0, totalChunks: chunks.count)
        for (ci, chunk) in chunks.enumerated() {
            progress(ci + 1, chunks.count)
            do {
                let dtos = try await parseChunk(chunk, provider: provider,
                                                apiKey: key, model: model)
                if dtos.isEmpty { throw AIError.badResponse("这一段没解析出题目") }
                outcome.dtos += dtos
            } catch {
                // 这段 AI 失败：回退本地解析器，能救回多少算多少
                outcome.fallbackChunks += 1
                if let r = try? QuestionImporter.parseFormattedText(chunk) {
                    outcome.dtos += r.dtos
                    outcome.skipped += r.skipped.count
                } else if blocks.isEmpty {
                    // 按字数硬切的段本地也无能为力，整段计跳过
                    outcome.skipped += 1
                } else {
                    outcome.skipped += min(8, blocks.count - ci * 8)
                }
            }
        }
        return outcome
    }

    // MARK: - 单段请求

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

    private static func parseChunk(_ chunk: String, provider: AIProvider,
                                   apiKey: String, model: String) async throws -> [QuestionDTO] {
        let prompt = """
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
    private static func decodeQuestions(from content: String) throws -> [QuestionDTO] {
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
        if type == "judge" && answer.isEmpty || (type == "judge" && !answer.allSatisfy({ "ABCDE".contains($0) })) {
            if answer.contains("正确") || answer == "对" || answer == "√" { answer = "A" }
            else if answer.contains("错误") || answer == "错" || answer == "×" { answer = "B" }
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
