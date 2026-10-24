import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// 本地 AI 解析：用苹果 Foundation Models 的端上模型（SystemLanguageModel）整理题目。
// 免费、不用 key、不用联网，但只有 iOS 26+ 且设备支持 Apple Intelligence 才有；
// 不可用时导入页干脆不显示这个选项，云端 AI 和普通解析完全不受影响。
// 端上模型上下文只有约 8192 token（中文约 1 字 1 token），所以分段比云端更碎：
// 每段原文控制在约 2000 字以内，每段开一个新会话、用完即弃。
// 返回格式与云端一致（提示词、JSON 解码、DTO 校验、失败回退本地解析全共用）。
// 7 版：与云端一样支持检查点跳过（existingSuffixes）和逐段回调落盘（onChunk），
// 另加 repair：智能模式下只修失败/可疑块，一块一个会话。
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

    private struct LocalChunk {
        var text: String
        var blockIndices: [Int]
        var suffix: String
    }

    // 把原文切成 ≤2000 字的小段：只收未入库的块；单块成段时后缀就是块后缀（续导最细）
    private static func makeChunks(from text: String,
                                   existingSuffixes: Set<String>)
        -> (chunks: [LocalChunk], skippedExisting: [String]) {
        let limit = 2000
        let blocks = QuestionImporter.splitBlocks(text)
        var skippedExisting: [String] = []
        guard !blocks.isEmpty else {
            var chunks: [LocalChunk] = []
            var rest = text
            var ti = 0
            while !rest.isEmpty {
                let part = rest.prefix(limit)
                rest = String(rest.dropFirst(part.count))
                let suffix = "t\(ti)"; ti += 1
                if existingSuffixes.contains(suffix) {
                    skippedExisting.append(suffix)
                    continue
                }
                chunks.append(LocalChunk(text: String(part), blockIndices: [], suffix: suffix))
            }
            return (chunks, skippedExisting)
        }
        for b in blocks where existingSuffixes.contains("b\(b.index)") {
            skippedExisting.append("b\(b.index)")
        }
        let pending = blocks.filter { !existingSuffixes.contains("b\($0.index)") }
        var chunks: [LocalChunk] = []
        var current: [RawBlock] = []
        var currentLen = 0
        func flush() {
            guard !current.isEmpty else { return }
            let suffix = current.count == 1
                ? "b\(current[0].index)"
                : "l\(current.first!.index)-\(current.last!.index)"
            if existingSuffixes.contains(suffix) {
                skippedExisting.append(suffix)
            } else {
                chunks.append(LocalChunk(
                    text: current.map(\.raw).joined(separator: "\n"),
                    blockIndices: current.map { $0.index },
                    suffix: suffix))
            }
            current = []
            currentLen = 0
        }
        for b in pending {
            if b.raw.count > limit {
                flush()
                // 单块超长：按字数硬切成 t 后缀段（归属只能到段）
                var rest = b.raw
                var ti = 0
                while !rest.isEmpty {
                    let part = rest.prefix(limit)
                    rest = String(rest.dropFirst(part.count))
                    let suffix = "t\(b.index)-\(ti)"; ti += 1
                    if existingSuffixes.contains(suffix) {
                        skippedExisting.append(suffix)
                        continue
                    }
                    chunks.append(LocalChunk(text: String(part), blockIndices: [b.index],
                                             suffix: suffix))
                }
            } else if currentLen + b.raw.count + 1 > limit {
                flush()
                current = [b]
                currentLen = b.raw.count
            } else {
                current.append(b)
                currentLen += b.raw.count + 1
            }
        }
        flush()
        return (chunks, skippedExisting)
    }

    static func parse(text: String,
                      existingSuffixes: Set<String> = [],
                      onChunk: (([KeyedDTO]) async -> Void)? = nil,
                      progress: @escaping (Int, Int) -> Void) async throws -> AIParseService.Outcome {
        guard isAvailable else {
            throw AIError.badResponse("这台设备现在用不了本地 AI（需要 iOS 26 以上且支持 Apple Intelligence）")
        }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return try await parseOnDevice(text: text, existingSuffixes: existingSuffixes,
                                           onChunk: onChunk, progress: progress)
        }
        #endif
        throw AIError.badResponse("系统版本不支持本地 AI")
    }

    // 智能模式的本地修复：一块一个会话，成功即回调落盘；失败的块如实上报
    static func repair(blocks: [RawBlock],
                       onChunk: (([KeyedDTO]) async -> Void)? = nil,
                       progress: @escaping (Int, Int) -> Void) async throws -> AIParseService.RepairOutcome {
        guard isAvailable else {
            throw AIError.badResponse("这台设备现在用不了本地 AI")
        }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return try await repairOnDevice(blocks: blocks, onChunk: onChunk, progress: progress)
        }
        #endif
        throw AIError.badResponse("系统版本不支持本地 AI")
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func runSession(_ text: String) async throws -> [QuestionDTO] {
        // 每段开一个新会话：端上上下文小，会话之间不带历史才不容易爆
        let session = LanguageModelSession()
        let response = try await session.respond(to: AIParseService.makePrompt(text))
        let dtos = try AIParseService.decodeQuestions(from: response.content)
        if dtos.isEmpty { throw AIError.badResponse("这一段没解析出题目") }
        return dtos
    }

    @available(iOS 26.0, *)
    private static func parseOnDevice(text: String,
                                      existingSuffixes: Set<String>,
                                      onChunk: (([KeyedDTO]) async -> Void)?,
                                      progress: @escaping (Int, Int) -> Void) async throws
        -> AIParseService.Outcome {
        let (chunks, skippedExisting) = makeChunks(from: text, existingSuffixes: existingSuffixes)
        var outcome = AIParseService.Outcome(
            totalBlocks: QuestionImporter.splitBlocks(text).count,
            totalChunks: chunks.count,
            skippedExistingSuffixes: skippedExisting)
        guard !chunks.isEmpty else {
            if skippedExisting.isEmpty { throw ImportError.empty }
            return outcome
        }
        for (ci, chunk) in chunks.enumerated() {
            progress(ci + 1, chunks.count)
            do {
                let dtos = try await runSession(chunk.text)
                let keyed: [KeyedDTO]
                if !chunk.blockIndices.isEmpty && dtos.count == chunk.blockIndices.count {
                    keyed = zip(dtos, chunk.blockIndices).map {
                        KeyedDTO(dto: $0.0, keySuffix: "b\($0.1)", origin: .ai)
                    }
                } else {
                    keyed = dtos.map { KeyedDTO(dto: $0, keySuffix: chunk.suffix, origin: .ai) }
                }
                outcome.aiSuccessChunks += 1
                outcome.keyed += keyed
                if let onChunk { await onChunk(keyed) }
            } catch {
                // 这段本地 AI 失败：回退普通解析器，能救回多少算多少（按块最终状态记）
                outcome.fallbackChunks += 1
                if let r = try? QuestionImporter.parseFormattedText(chunk.text) {
                    let keyed = r.dtos.map {
                        KeyedDTO(dto: $0, keySuffix: chunk.suffix, origin: .rule)
                    }
                    outcome.keyed += keyed
                    outcome.skipped += r.skipped.count
                    if let onChunk, !keyed.isEmpty { await onChunk(keyed) }
                } else if chunk.blockIndices.isEmpty {
                    outcome.skipped += 1
                } else {
                    outcome.skipped += chunk.blockIndices.count
                }
            }
        }
        return outcome
    }

    @available(iOS 26.0, *)
    private static func repairOnDevice(blocks: [RawBlock],
                                       onChunk: (([KeyedDTO]) async -> Void)?,
                                       progress: @escaping (Int, Int) -> Void) async throws
        -> AIParseService.RepairOutcome {
        var result = AIParseService.RepairOutcome()
        for (i, b) in blocks.enumerated() {
            progress(i + 1, blocks.count)
            do {
                let dtos = try await runSession(b.raw)
                let keyed = dtos.map {
                    KeyedDTO(dto: $0, keySuffix: "b\(b.index)", origin: .ai)
                }
                result.keyed += keyed
                result.repairedBlocks.append(b.index)
                if let onChunk { await onChunk(keyed) }
            } catch {
                result.failedBlocks.append(b.index)
            }
        }
        return result
    }
    #endif
}
