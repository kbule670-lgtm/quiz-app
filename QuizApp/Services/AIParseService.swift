import Foundation

// 临时空壳（仅用于定位编译错误）：签名与正式版一致，parse 直接抛错
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

    var defaultModel: String {
        switch self {
        case .deepseek: return "deepseek-v4-flash"
        case .doubao: return ""
        case .qianwen: return "qwen-plus"
        }
    }

    var modelEditable: Bool { true }
    var modelPlaceholder: String {
        self == .doubao ? "填接入点 ID，如 ep-2024…" : defaultModel
    }
}

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
        case .noKey: return "还没填 API key"
        case .noModel: return "还没填模型名"
        case .http(let code, let body): return "AI 接口返回错误（HTTP \(code)）：\(body.prefix(120))"
        case .badResponse(let msg): return "AI 返回的内容看不懂：\(msg)"
        }
    }
}

enum ImportAIMode: String, CaseIterable, Identifiable {
    case normal
    case local
    case cloud

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: return "普通解析"
        case .local: return "本地 AI"
        case .cloud: return "云端 AI"
        }
    }
}

enum AIParseService {
    struct Outcome {
        var dtos: [QuestionDTO]
        var skipped: Int
        var totalBlocks: Int
        var fallbackChunks: Int
        var totalChunks: Int
    }

    static func parse(text: String, provider: AIProvider,
                      progress: @escaping (Int, Int) -> Void) async throws -> Outcome {
        throw AIError.badResponse("stub")
    }
}
