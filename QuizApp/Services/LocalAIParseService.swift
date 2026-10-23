import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// 本地 AI 解析：用苹果 Foundation Models 的端上模型（SystemLanguageModel）整理题目。
// 免费、不用 key、不用联网，但只有 iOS 26+ 且设备支持 Apple Intelligence 才有；
// 不可用时导入页干脆不显示这个选项，云端 AI 和普通解析完全不受影响。
// 端上模型上下文只有约 8192 token（中文约 1 字 1 token），所以分段比云端更碎：
// 每段原文控制在约 2000 字以内，每段开一个新会话、用完即弃。
// 返回格式与云端一致（提示词、JSON 解码、DTO 入库、失败回退本地解析全共用）。
enum LocalAIParseService {

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return true
            default:
                return false
            }
        }
        #endif
        return false
    }

    static func parse(text: String,
                      progress: @escaping (Int, Int) -> Void) async throws -> AIParseService.Outcome {
        guard isAvailable else {
            throw AIError.badResponse("这台设备现在用不了本地 AI（需要 iOS 26 以上且支持 Apple Intelligence）")
        }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return try await parseOnDevice(text: text, progress: progress)
        }
        #endif
        throw AIError.badResponse("系统版本不支持本地 AI")
    }

    // 把原文切成 ≤2000 字的小段：先按题号块攒，单块超长就按字数硬切
    private static func makeChunks(from text: String) -> [String] {
        let limit = 2000
        let blocks = QuestionImporter.splitBlocks(text)
        guard !blocks.isEmpty else {
            var chunks: [String] = []
            var rest = text
            while !rest.isEmpty {
                let part = rest.prefix(limit)
                chunks.append(String(part))
                rest = String(rest.dropFirst(part.count))
            }
            return chunks
        }
        var chunks: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { chunks.append(current); current = "" }
        }
        for b in blocks {
            let raw = b.raw
            if raw.count > limit {
                flush()
                var rest = raw
                while !rest.isEmpty {
                    let part = rest.prefix(limit)
                    chunks.append(String(part))
                    rest = String(rest.dropFirst(part.count))
                }
            } else if current.count + raw.count + 1 > limit {
                flush()
                current = raw
            } else {
                current = current.isEmpty ? raw : current + "\n" + raw
            }
        }
        flush()
        return chunks
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func parseOnDevice(text: String,
                                      progress: @escaping (Int, Int) -> Void) async throws
        -> AIParseService.Outcome {
        let chunks = makeChunks(from: text)
        guard !chunks.isEmpty else { throw ImportError.empty }
        var outcome = AIParseService.Outcome(
            dtos: [], skipped: 0,
            totalBlocks: QuestionImporter.splitBlocks(text).count,
            fallbackChunks: 0, totalChunks: chunks.count)
        for (ci, chunk) in chunks.enumerated() {
            progress(ci + 1, chunks.count)
            do {
                // 每段开一个新会话：端上上下文小，会话之间不带历史才不容易爆
                let session = LanguageModelSession()
                let response = try await session.respond(
                    to: AIParseService.makePrompt(chunk))
                let dtos = try AIParseService.decodeQuestions(from: response.content)
                if dtos.isEmpty { throw AIError.badResponse("这一段没解析出题目") }
                outcome.dtos += dtos
            } catch {
                // 这段本地 AI 失败：回退普通解析器，能救回多少算多少
                outcome.fallbackChunks += 1
                if let r = try? QuestionImporter.parseFormattedText(chunk) {
                    outcome.dtos += r.dtos
                    outcome.skipped += r.skipped.count
                } else {
                    outcome.skipped += 1
                }
            }
        }
        return outcome
    }
    #endif
}
