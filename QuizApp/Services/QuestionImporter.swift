import Foundation

// 导入前的数据形态：跟 Question 一样，只是还没进数据库
struct QuestionDTO {
    var stem: String
    var options: [String] // 单选/多选 2-5 个，判断 2 个
    var answerIndex: Int // 单选答案 0-4（多选时占位 0）
    var explanation: String
    var isMulti: Bool = false
    var answerIndices: [Int] = [] // 多选的正确答案集合
}

enum ImportError: LocalizedError {
    case empty
    case badFormat(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "文件里没有读到题目"
        case .badFormat(let msg):
            return "格式不对：" + msg
        }
    }
}

// 切出来的一个题块（切题器产物，带定位信息供分段入库/续导/智能修复用）
struct RawBlock {
    var index: Int          // 块序号（同版本切题器对同一文本确定性输出，序号稳定）
    var number: Int?        // 题号标记里的数字（抠不到为 nil）
    var score: Int          // 边界置信评分
    var typeHint: String?   // 单选 / 多选 / 判断 / 填空
    var body: String        // 题号标记之后的正文
    var raw: String         // 原文整块（含题号标记）
}

// 解析成功的题（带回块定位与疑似标记）
struct ParsedItem {
    var dto: QuestionDTO
    var blockIndex: Int
    var suspect: Bool       // 通过校验但可疑（题干过短/疑似粘连残留），智能模式会送 AI 复核
    var suspectReason: String
}

// 没通过校验的块：保留原文与原因，进智能模式修复队列；修不好计「未救回」，绝不静默丢弃
struct SkippedBlock {
    var index: Int
    var number: Int?
    var raw: String
    var reason: String
}

struct ParseResult {
    var items: [ParsedItem]
    var skipped: [SkippedBlock]
    var blocks: [RawBlock]
}

// 题库导入：JSON 和 CSV 两种都认，题库格式她自己定，两种格式任选其一
enum QuestionImporter {

    // 解析器版本：切题/解析逻辑任何改动必须 +1。
    // sourceKey = 文件指纹 + 版本 + 块序号，只在同版本内做续导/去重；
    // 版本变了不沿用旧检查点，靠内容哈希层防重复（见 ImportView 的插入器）。
    static let parserVersion = 2

    static func sourceKey(fingerprint: String, suffix: String) -> String {
        "\(fingerprint)#v\(parserVersion)#\(suffix)"
    }

    // 文件指纹：整份文件数据的 SHA256
    static func sha256Hex(_ data: Data) -> String { SHA256.hex(data) }

    // 内容哈希（跨版本防重复用）：归一化白名单只有三样——
    // 全角转半角、连续空白/换行折叠成单个空格、首尾 trim。
    // 严禁删改标点/数字/字母：题干只差一个数字就是不同的题，哈希必须不同。
    static func contentHash(stem: String, options: [String], answerText: String) -> String {
        let parts = [normalizeForHash(stem)]
            + options.map { normalizeForHash($0) }
            + [normalizeForHash(answerText)]
        return SHA256.hex(Data(parts.joined(separator: "\u{1}").utf8))
    }

    static func contentHash(for dto: QuestionDTO) -> String {
        contentHash(stem: dto.stem, options: dto.options,
                    answerText: answerText(isMulti: dto.isMulti,
                                           answerIndex: dto.answerIndex,
                                           answerIndices: dto.answerIndices))
    }

    // 从已存的 Question 行重建答案字母串（与 DTO 口径一致）
    static func answerText(isMulti: Bool, answerIndex: Int, answerIndices: [Int]) -> String {
        if isMulti {
            return answerIndices.sorted()
                .filter { allLetters.indices.contains($0) }
                .map { allLetters[$0] }.joined()
        }
        return allLetters.indices.contains(answerIndex) ? allLetters[answerIndex] : ""
    }

    private static func normalizeForHash(_ s: String) -> String {
        var mapped = ""
        for scalar in s.unicodeScalars {
            if scalar.value >= 0xFF01 && scalar.value <= 0xFF5E {
                // 全角 ASCII 区 → 半角
                mapped.unicodeScalars.append(UnicodeScalar(scalar.value - 0xFEE0)!)
            } else if scalar.value == 0x3000 {
                mapped.append(" ")
            } else {
                mapped.unicodeScalars.append(scalar)
            }
        }
        // 连续空白/换行折叠为单个空格 + 首尾 trim
        return mapped.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // 选项字母全集：马原题库的多选题有 A-E 五个选项（答案能到 BCDE）
    static let allLetters = ["A", "B", "C", "D", "E"]
    static let allLetterChars = "ABCDE"

    // JSON 长这样：
    // [{"stem":"题干","options":["A项","B项","C项","D项"],"answer":"B","explanation":"解析，可空"}]
    // 多选题把 answer 写成 "AC"，或用 "answers":["A","C"]；选项最多 5 个（A-E）
    static func fromJSON(_ data: Data) throws -> [QuestionDTO] {
        struct Raw: Decodable {
            var stem: String
            var options: [String]
            var answer: String?
            var answers: [String]?
            var explanation: String?
        }
        let raws = try JSONDecoder().decode([Raw].self, from: data)
        return try raws.enumerated().map { i, r in
            let letters = (r.answers ?? [r.answer ?? ""])
                .joined()
                .uppercased()
                .filter { allLetterChars.contains($0) }
            let unique = Array(Set(letters)).sorted()
            if unique.count > 1 {
                return try dtoMulti(stem: r.stem, options: r.options,
                                    answerLetters: unique.map { String($0) },
                                    explanation: r.explanation ?? "", line: i + 1)
            }
            return try dto(stem: r.stem, options: r.options,
                           answerLetter: String(unique.first ?? " "),
                           explanation: r.explanation ?? "", line: i + 1)
        }
    }

    // CSV 长这样（第一行是表头，别删）：
    // 题干,选项A,选项B,选项C,选项D,答案,解析
    // 也可以多一列选项E：题干,选项A,选项B,选项C,选项D,选项E,答案,解析
    static func fromCSV(_ text: String) throws -> [QuestionDTO] {
        let rows = parseCSV(text)
        guard rows.count >= 2 else { throw ImportError.empty }
        return try rows.dropFirst().enumerated().compactMap { i, cols in
            // 跳过空行
            if cols.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                return nil
            }
            guard cols.count >= 6 else {
                throw ImportError.badFormat("第 \(i + 2) 行列数不够（要 6 列：题干,A,B,C,D,答案）")
            }
            // 8 列及以上按带 E 选项的版式读：题干,A,B,C,D,E,答案,解析
            let hasE = cols.count >= 8
            let options = hasE ? Array(cols[1...5]) : Array(cols[1...4])
            let answerCol = hasE ? cols[6] : cols[5]
            let explanation = hasE ? cols[7] : (cols.count > 6 ? cols[6] : "")
            // 答案列写一个字母是单选，写 AC 这样连着的是多选
            let letters = answerCol.uppercased().filter { allLetterChars.contains($0) }
            let unique = Array(Set(letters)).sorted()
            if unique.count > 1 {
                return try dtoMulti(stem: cols[0], options: options,
                                    answerLetters: unique.map { String($0) },
                                    explanation: explanation,
                                    line: i + 2)
            }
            return try dto(stem: cols[0], options: options,
                           answerLetter: answerCol,
                           explanation: explanation,
                           line: i + 2)
        }
    }

    // 统一校验：题干非空、2-5 个非空选项、答案是 A-E 之一
    static func dto(stem: String, options: [String], answerLetter: String,
                    explanation: String, line: Int) throws -> QuestionDTO {
        let s = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else {
            throw ImportError.badFormat("第 \(line) 行题干是空的")
        }
        let opts = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard (2...5).contains(opts.count), opts.allSatisfy({ !$0.isEmpty }) else {
            throw ImportError.badFormat("第 \(line) 行选项必须是 2 到 5 个非空的（判断题 2 个、单选/多选题 4-5 个）")
        }
        let letter = answerLetter.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let idx = allLetters.firstIndex(of: letter), idx < opts.count else {
            throw ImportError.badFormat("第 \(line) 行答案必须是 A/B/C/D/E 之一且不能超出选项，写的是「\(answerLetter)」")
        }
        return QuestionDTO(stem: s, options: opts, answerIndex: idx, explanation: explanation)
    }

    // 多选题校验：答案至少 2 个字母、不重复、都在选项范围内
    static func dtoMulti(stem: String, options: [String], answerLetters: [String],
                         explanation: String, line: Int) throws -> QuestionDTO {
        let s = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else {
            throw ImportError.badFormat("第 \(line) 行题干是空的")
        }
        let opts = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard (2...5).contains(opts.count), opts.allSatisfy({ !$0.isEmpty }) else {
            throw ImportError.badFormat("第 \(line) 行选项必须是 2 到 5 个非空的")
        }
        var indices: [Int] = []
        for l in answerLetters {
            let u = l.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard let idx = allLetters.firstIndex(of: u), idx < opts.count else {
                throw ImportError.badFormat("第 \(line) 行多选答案「\(l)」不对")
            }
            if !indices.contains(idx) { indices.append(idx) }
        }
        guard indices.count >= 2 else {
            throw ImportError.badFormat("第 \(line) 行多选题答案至少要有 2 个")
        }
        return QuestionDTO(stem: s, options: opts, answerIndex: indices.sorted()[0],
                           explanation: explanation, isMulti: true,
                           answerIndices: indices.sorted())
    }

    // MARK: - 归一化

    // OCR 常见误认先归一化：全角方括号/圆括号/【】、全角数字、全角字母都换成半角，
    // 切题与抠字段都在归一化后的文本上做（存进题库的题干也因此统一成半角括号）
    static func normalize(_ rawText: String) -> String {
        var text = rawText
            .replacingOccurrences(of: "［", with: "[")
            .replacingOccurrences(of: "］", with: "]")
            .replacingOccurrences(of: "【", with: "[")
            .replacingOccurrences(of: "】", with: "]")
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
        for (i, full) in ["Ａ", "Ｂ", "Ｃ", "Ｄ", "Ｅ"].enumerated() {
            text = text.replacingOccurrences(of: full, with: allLetters[i])
        }
        for (i, full) in ["０", "１", "２", "３", "４", "５", "６", "７", "８", "９"].enumerated() {
            text = text.replacingOccurrences(of: full, with: String(i))
        }
        return text
    }

    // MARK: - 切题器（候选 → 评分 → 边界 + 粘连自检劈开）

    private enum MarkerKind {
        case bracketClosed      // [25](单选) / [25][单选] / [25]
        case bracketMissing     // [146(单选) —— 数字后缺 ]
        case loneBracket        // [146 题干……（只有 [ 和数字）
        case paren              // (25) / (25)(单选)
        case diTi               // 第146题
        case bareHint           // 146(单选)
        case dotted             // 行首 146.

        var baseScore: Int {
            switch self {
            case .bracketClosed, .bracketMissing, .paren, .diTi, .bareHint: return 3
            case .loneBracket, .dotted: return 2
            }
        }
    }

    private struct Candidate {
        var range: NSRange      // 整个标记（含题型标记）
        var number: Int
        var hint: String?
        var kind: MarkerKind
        var atLineStart: Bool
        var score: Int
    }

    // 候选标记正则：归一化后括号都是半角。分组编号与 candidate(from:) 一一对应：
    // 1,2=[n](型) 3,4=[n(型) 5=[n 6,7=(n)(型) 8=第n题 9,10=n(型) 11=行首n.
    private static let candidatePattern =
        "\\[(\\d{1,4})\\][ \\t]*(?:[\\[(]?(单选|多选|判断|填空)[\\]\\)])?" +
        "|\\[(\\d{1,4})[ \\t]*[\\[(](单选|多选|判断|填空)[\\]\\)]?" +
        "|\\[(\\d{1,4})(?=[ \\t])" +
        "|\\((\\d{1,4})\\)[ \\t]*(?:[\\[(]?(单选|多选|判断|填空)[\\]\\)])?" +
        "|第[ \\t]*(\\d{1,4})[ \\t]*题" +
        "|(\\d{1,4})[ \\t]*[\\[(](单选|多选|判断|填空)[\\]\\)]" +
        "|(?m)^[ \\t]*(\\d{1,4})[ \\t]*[.、.)]"

    private static func candidate(from m: NSTextCheckingResult, in ns: NSString) -> Candidate? {
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location != NSNotFound ? ns.substring(with: r) : nil
        }
        let kind: MarkerKind
        let numStr: String?
        let hint: String?
        if let n = group(1) { kind = .bracketClosed; numStr = n; hint = group(2) }
        else if let n = group(3) { kind = .bracketMissing; numStr = n; hint = group(4) }
        else if let n = group(5) { kind = .loneBracket; numStr = n; hint = nil }
        else if let n = group(6) { kind = .paren; numStr = n; hint = group(7) }
        else if let n = group(8) { kind = .diTi; numStr = n; hint = nil }
        else if let n = group(9) { kind = .bareHint; numStr = n; hint = group(10) }
        else if let n = group(11) { kind = .dotted; numStr = n; hint = nil }
        else { return nil }
        guard let num = numStr.flatMap({ Int($0) }), num >= 1 else { return nil }
        // 是否行首：往前跳过空格/制表符，到文本头或换行即是
        var atLineStart = false
        var p = m.range.location - 1
        while p >= 0 {
            let ch = ns.character(at: p)
            if ch == 0x20 || ch == 0x09 { p -= 1; continue }
            atLineStart = (ch == 0x0A || ch == 0x0D)
            break
        }
        if p < 0 { atLineStart = true }
        return Candidate(range: m.range, number: num, hint: hint,
                         kind: kind, atLineStart: atLineStart, score: 0)
    }

    // 在指定范围内找全部候选并打基础分（不含连续性分，连续性由调用方按顺序补）
    private static func findCandidates(in ns: NSString, range: NSRange) -> [Candidate] {
        guard let re = try? NSRegularExpression(pattern: candidatePattern) else { return [] }
        let matches = re.matches(in: ns as String, range: range)
        var result: [Candidate] = []
        for (mi, m) in matches.enumerated() {
            guard var c = candidate(from: m, in: ns) else { continue }
            var score = c.kind.baseScore
            if c.hint != nil { score += 3 }
            // 其后（到下一个候选或 600 字内）有没有合理选项结构
            let winStart = m.range.upperBound
            let winEnd = min(ns.length,
                             mi + 1 < matches.count ? matches[mi + 1].range.location : winStart + 600)
            if winEnd > winStart {
                let window = ns.substring(with: NSRange(location: winStart, length: winEnd - winStart))
                if hasOptionStructure(window) { score += 3 }
            }
            // 前面刚出现过答案行（上一题刚结束的强信号）
            let backStart = max(0, m.range.location - 48)
            if backStart < m.range.location {
                let back = ns.substring(with: NSRange(location: backStart,
                                                      length: m.range.location - backStart))
                if firstMatch("(?:答案|正确答案)[ \\t]*[:：]?[ \\t]*(?:[ABCDE]|正确|错误)",
                              in: back) != nil { score += 3 }
            }
            // 句中出现又没题型标记的，大概率是正文里的引用/数字
            if !c.atLineStart && c.hint == nil { score -= 3 }
            // 1900-2099 又没题型标记的，多半是正文里引用的年份（如 [2021]）不是题号；
            // 真题号靠题型标记+连续性照样能过线（本系列题库题号最大 1548，不受影响）
            if c.hint == nil && (1900...2099).contains(c.number) { score -= 3 }
            c.score = score
            result.append(c)
        }
        return result
    }

    // 窗口里有没有选项结构：A、B 两个标记按序出现，或「正确/错误」成对出现
    private static func hasOptionStructure(_ window: String) -> Bool {
        if window.contains("正确") && window.contains("错误") { return true }
        guard let re = try? NSRegularExpression(pattern: "([ABCDE])[ \\t]*[.、．:：]") else {
            return false
        }
        let ns = window as NSString
        let ms = re.matches(in: window, range: NSRange(location: 0, length: ns.length))
        var seenA = false
        for m in ms {
            let letter = ns.substring(with: m.range(at: 1))
            if letter == "A" { seenA = true }
            else if letter == "B" && seenA { return true }
        }
        return false
    }

    // 连续性补分 + 阈值过滤：在全文范围内选出真正的题界
    private static func selectBoundaries(_ candidates: [Candidate]) -> [Candidate] {
        var accepted: [Candidate] = []
        var lastNumber: Int? = nil
        for var c in candidates {
            var continuity = 0
            if let last = lastNumber {
                if c.number == last + 1 { continuity = 2 }
                else if c.number == 1 { continuity = 2 }       // 分节后题号从 1 重排
                else if c.number > last { continuity = 1 }
            }
            c.score += continuity
            // 行首点号题号最弱：没题型、没连续性、前面也没答案行时不认，防正文年份/序号误切。
            // 只在已切出过题界之后启用：文档第一题（如模板的「1.」）没有前文可佐证，
            // 光靠选项结构就该认；题号为 1 的同理豁免。
            if c.kind == .dotted && c.hint == nil && continuity == 0
                && lastNumber != nil && c.number != 1
                && c.score - continuity < 6 { c.score -= 3 }
            if c.score >= 5 {
                accepted.append(c)
                lastNumber = c.number
            }
        }
        return accepted
    }

    // 切块：先按评分选界，再逐块做粘连自检——块内（题号标记之后）若再出现
    // 高分候选（习思那种上一题 D 选项吞进下一题），从该处劈开，尾块递归再检。
    static func splitBlocks(_ rawText: String) -> [RawBlock] {
        let text = normalize(rawText)
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let boundaries = selectBoundaries(findCandidates(in: ns, range: full))
        guard !boundaries.isEmpty else { return [] }

        var spans: [(start: Int, markerEnd: Int, number: Int, hint: String?, score: Int)] = []
        for b in boundaries {
            spans.append((b.range.location, b.range.upperBound, b.number, b.hint, b.score))
        }
        // 粘连自检劈开（带深度上限，防递归失控）
        var finalSpans: [(start: Int, markerEnd: Int, end: Int, number: Int, hint: String?, score: Int)] = []
        for (i, s) in spans.enumerated() {
            let end = i + 1 < spans.count ? spans[i + 1].start : ns.length
            splitSpan(ns: ns, start: s.start, markerEnd: s.markerEnd, end: end,
                      number: s.number, hint: s.hint, score: s.score,
                      depth: 0, into: &finalSpans)
        }
        return finalSpans.enumerated().map { i, s in
            RawBlock(index: i, number: s.number, score: s.score, typeHint: s.hint,
                     body: ns.substring(with: NSRange(location: s.markerEnd,
                                                      length: s.end - s.markerEnd)),
                     raw: ns.substring(with: NSRange(location: s.start,
                                                     length: s.end - s.start)))
        }
    }

    private static func splitSpan(ns: NSString, start: Int, markerEnd: Int, end: Int,
                                  number: Int, hint: String?, score: Int, depth: Int,
                                  into out: inout [(start: Int, markerEnd: Int, end: Int,
                                                    number: Int, hint: String?, score: Int)]) {
        if depth < 3 && end - markerEnd > 10 {
            let inner = findCandidates(in: ns, range: NSRange(location: markerEnd,
                                                              length: end - markerEnd))
            for c in inner {
                // 块内候选要更硬：有题型标记或闭合括号式，且总分（含与本题连续）≥ 8
                var s = c.score
                if c.number == number + 1 { s += 2 }
                let hardForm = c.hint != nil || c.kind == .bracketClosed || c.kind == .paren
                if hardForm && s >= 8 {
                    // 在 c 处劈开：前半收尾，后半作为新块递归再检
                    out.append((start, markerEnd, c.range.location, number, hint, score))
                    splitSpan(ns: ns, start: c.range.location, markerEnd: c.range.upperBound,
                              end: end, number: c.number, hint: c.hint, score: s,
                              depth: depth + 1, into: &out)
                    return
                }
            }
        }
        out.append((start, markerEnd, end, number, hint, score))
    }

    // 某段文本里是否还嵌着题目标记（给已解析题做粘连残留嫌疑判定用）
    static func containsEmbeddedMarker(_ text: String) -> Bool {
        let ns = text as NSString
        let cands = findCandidates(in: ns, range: NSRange(location: 0, length: ns.length))
        return cands.contains {
            $0.hint != nil || $0.kind == .bracketClosed || $0.kind == .paren || $0.kind == .diTi
        }
    }

    // MARK: - 文字版解析（状态机抠字段）

    // 文字版题库：PDF / Word / txt 里提取出的文字都走这个解析器。认这种最常见的排版：
    // [1](单选) 题干（可以占好几行）
    // A. 选项一 B. 选项二 （选项一行一个、或几个挤一行，都行；最多到 E）
    // 答案：B（多选写 答案：BCDE；判断题也可以写 答案：正确）
    // 解析：可有可无
    // 答案也可以写成题干末尾的（B）这种形式。
    static func parseDetailed(_ rawText: String) -> ParseResult {
        let blocks = splitBlocks(rawText)
        var bodies = blocks.map { $0.body }
        // 答案行再平衡：块 i 没有任何答案、块 i+1 却有 ≥2 个答案行时，末位答案行
        // 多半是块 i 的（粘连时上一题的答案行落在下一题块尾），移回去再解析
        for i in 0..<max(0, bodies.count - 1) {
            let receiver = bodies[i]
            let hasBracketAnswer = firstMatch(#"[(（][ \t]*[ABCDE][ \t]*[)）]"#, in: receiver) != nil
            if countAnswerLines(receiver) == 0 && !hasBracketAnswer
                && countAnswerLines(bodies[i + 1]) >= 2,
               let moved = extractLastAnswerLine(&bodies[i + 1]) {
                bodies[i] = receiver + "\n" + moved
            }
        }
        var items: [ParsedItem] = []
        var skipped: [SkippedBlock] = []
        for b in blocks {
            do {
                let dto = try parseBlock(bodies[b.index], index: b.index, typeHint: b.typeHint)
                var suspect = false
                var reason = ""
                if dto.stem.count < 4 {
                    suspect = true; reason = "题干异常短"
                }
                if !suspect && dto.options.contains(where: {
                    containsEmbeddedMarker($0) || $0.contains("答案：") || $0.contains("答案:")
                }) {
                    suspect = true; reason = "选项里疑似混入了下一题的内容"
                }
                if !suspect && countAnswerLines(bodies[b.index]) >= 2 {
                    suspect = true; reason = "一块里有多个答案行，疑似两题粘连"
                }
                items.append(ParsedItem(dto: dto, blockIndex: b.index,
                                        suspect: suspect, suspectReason: reason))
            } catch let e as ImportError {
                skipped.append(SkippedBlock(index: b.index, number: b.number,
                                            raw: b.raw, reason: e.errorDescription ?? "解析失败"))
            } catch {
                skipped.append(SkippedBlock(index: b.index, number: b.number,
                                            raw: b.raw, reason: "解析失败"))
            }
        }
        return ParseResult(items: items, skipped: skipped, blocks: blocks)
    }

    private static func countAnswerLines(_ body: String) -> Int {
        guard let re = try? NSRegularExpression(pattern: "(?:答案|正确答案)[ \\t]*[:：]") else {
            return 0
        }
        return re.numberOfMatches(in: body, range: NSRange(location: 0, length: (body as NSString).length))
    }

    // 抠出正文里最后一个答案行（到行尾为止）并从正文里删掉，抠不到返回 nil
    private static func extractLastAnswerLine(_ body: inout String) -> String? {
        guard let re = try? NSRegularExpression(
            pattern: "(?:答案|正确答案)[ \t]*[:：][^\n]*") else { return nil }
        let ns = body as NSString
        let matches = re.matches(in: body, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last else { return nil }
        let line = ns.substring(with: last.range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        body = replace(body, range: last.range, with: "")
        return line.isEmpty ? nil : line
    }

    // 兼容旧接口：跳过清单从 [Int] 升级为 [SkippedBlock]（带块序号与原文）
    static func parseFormattedText(_ rawText: String) throws
        -> (dtos: [QuestionDTO], skipped: [SkippedBlock], blocks: Int) {
        let blocks = splitBlocks(rawText)
        guard !blocks.isEmpty else {
            throw ImportError.badFormat("没找到题号（一行一道、题号开头的格式），看看填写说明里的文字版模板")
        }
        let r = parseDetailed(rawText)
        return (r.items.map { $0.dto }, r.skipped, r.blocks.count)
    }

    static func fromFormattedText(_ text: String) throws -> [QuestionDTO] {
        let r = try parseFormattedText(text)
        if r.dtos.isEmpty {
            throw ImportError.badFormat("一道题都没认出来，看看填写说明里的文字版模板")
        }
        return r.dtos
    }

    // 单块解析（状态机：题干 → 选项 → 答案/解析，字段逐段抠出后互相剥离）
    static func parseBlock(_ rawBlock: String, index bi: Int,
                           typeHint: String?) throws -> QuestionDTO {
        var block = rawBlock

        // 1) 判断题文字答案先抠：答案：正确 / 答案：错误（也可能是 对/错）
        var judgeAnswerLetter: String? = nil
        if let jm = firstMatch("(?:答案|正确答案)[ \\t]*[:：][ \\t]*(正确|错误|对|错)", in: block) {
            let word = (block as NSString).substring(with: jm.range(at: 1))
            judgeAnswerLetter = (word == "正确" || word == "对") ? "A" : "B"
            block = replace(block, range: jm.range, with: "")
        }
        // 2) 字母答案：答案：B；多选写成 答案：BCDE，抠出全部字母
        var answerLetters: [String] = []
        if let am = firstMatch("(?:【)?(?:答案|正确答案)(?:】)?[ \\t]*[:：]?[ \\t]*([ABCDE](?:[ \\t]*[,，、和]?[ \\t]*[ABCDE])*)", in: block) {
            let raw = (block as NSString).substring(with: am.range(at: 1))
            answerLetters = raw.filter { allLetterChars.contains($0) }.map { String($0) }
            block = replace(block, range: am.range, with: "")
        }
        // 3) 解析：解析：……一直到这道题结束
        var explanation = ""
        if let em = firstMatch(#"(?:解析|答案解析|试题解析)[ \t]*[:：]"#, in: block) {
            let s = (em.range.location + em.range.length)
            explanation = ((block as NSString).substring(from: s))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            block = (block as NSString).substring(to: em.range.location)
        }
        // 4) 答案没单独写的话，认题干/选项里括号包着的：(B)
        if answerLetters.isEmpty && judgeAnswerLetter == nil,
           let am = firstMatch(#"[(（][ \t]*([ABCDE])[ \t]*[)）]"#, in: block) {
            answerLetters = [(block as NSString).substring(with: am.range(at: 1))]
            block = replace(block, range: am.range, with: "")
        }
        guard !answerLetters.isEmpty || judgeAnswerLetter != nil else {
            throw ImportError.badFormat("第 \(bi + 1) 题没找到答案（要写「答案：B」或在题干后标（B））")
        }
        // 去重保序
        var seen = Set<String>()
        answerLetters = answerLetters.filter { seen.insert($0).inserted }

        // 5) 抠选项：找 A. B. C. D. E. 标记，标记之间就是选项内容。
        // 理想情况字母从 A 起严格连续；OCR 串行时可能多出重复/乱序标记，
        // 这时贪心只收「下一个该出现的字母」，把串掉的标记丢掉，别整道扔。
        let optRe = try NSRegularExpression(pattern: #"([ABCDE])[ \t]*[.、．:：]"#)
        let bns = block as NSString
        let allOpts = optRe.matches(in: block, range: NSRange(location: 0, length: bns.length))
        var opts: [NSTextCheckingResult] = []
        for m in allOpts {
            let letter = bns.substring(with: m.range(at: 1))
            if letter == allLetters[opts.count] { opts.append(m) }
        }
        let n = opts.count
        guard (2...5).contains(n) else {
            throw ImportError.badFormat("第 \(bi + 1) 题选项没凑齐（单选要 A、B、C、D，多选可到 E，判断要 A、B）")
        }
        var stem = bns.substring(to: opts[0].range.location)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 题型标记要是没被题号正则吃掉（比如单独占了一行），从题干开头摘掉
        if let tm = firstMatch("^[\\[(（](?:单选|多选|判断|填空)[\\]\\)）][ \\t]*", in: stem) {
            stem = replace(stem, range: tm.range, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var options: [String] = []
        for i in 0..<n {
            let s = opts[i].range.upperBound
            let e = i + 1 < n ? opts[i + 1].range.location : bns.length
            options.append(bns.substring(with: NSRange(location: s, length: e - s))
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // 6) 判断题：与既有存储口径完全一致——options 固定 [正确，错误]、
        // 答案 A=正确 / B=错误，走同一个 dto 入口，不引入新格式。
        let judgeOptionTexts = options.map { judgeNormalized($0) }
        let looksJudge = n == 2 && judgeOptionTexts == ["正确", "错误"]
        if typeHint == "判断" || judgeAnswerLetter != nil || looksJudge {
            if looksJudge {
                let letter = judgeAnswerLetter ?? answerLetters.first ?? ""
                return try dto(stem: stem, options: ["正确", "错误"],
                               answerLetter: letter, explanation: explanation, line: bi + 1)
            }
            if judgeAnswerLetter != nil && answerLetters.isEmpty {
                // 说是判断题、答案也是文字，但选项不是「正确/错误」形态：数据自相矛盾，判失败进修复队列
                throw ImportError.badFormat("第 \(bi + 1) 题判断题选项对不上（不是正确/错误）")
            }
            // 题型标了判断但选项是普通多选项：按普通题走下面的路径，别把题扔了
        }
        // 7) 定题型：答案字母超过 1 个就是多选；题型标记写了多选、但只抠到 1 个
        // 答案字母时按单选收（同旧版口径）。
        if answerLetters.count > 1 {
            return try dtoMulti(stem: stem, options: options,
                                answerLetters: answerLetters,
                                explanation: explanation, line: bi + 1)
        }
        let single = answerLetters.first ?? judgeAnswerLetter ?? ""
        return try dto(stem: stem, options: options, answerLetter: single,
                       explanation: explanation, line: bi + 1)
    }

    // 判断题选项文字归一：对/√→正确，错/×→错误，其余原样返回
    private static func judgeNormalized(_ option: String) -> String {
        let t = option.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "对" || t == "√" || t == "正确" { return "正确" }
        if t == "错" || t == "×" || t == "错误" { return "错误" }
        if t.contains("正确") && !t.contains("错误") { return "正确" }
        if t.contains("错误") { return "错误" }
        return t
    }

    private static func firstMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        return re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func replace(_ text: String, range: NSRange, with: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: with)
    }

    // 最小可用 CSV 解析：认双引号包裹，逗号/换行在引号里不算分隔符
    private static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\""); i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                if c == "\"" {
                    inQuotes = true
                } else if c == "," {
                    row.append(field); field = ""
                } else if c == "\n" || c == "\r" {
                    if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                    row.append(field); field = ""
                    rows.append(row); row = []
                } else {
                    field.append(c)
                }
            }
            i += 1
        }
        row.append(field)
        rows.append(row)
        return rows
    }
}

// MARK: - 纯 Swift SHA256（不依赖 CryptoKit，保证本地工具链也能验）

private enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hex(_ data: Data) -> String {
        hash(data).map { String(format: "%02x", $0) }.joined()
    }

    static func hash(_ data: Data) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                           0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var msg = [UInt8](data)
        let bitLen = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() {
            msg.append(UInt8((bitLen >> UInt64(i * 8)) & 0xff))
        }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunkStart in stride(from: 0, to: msg.count, by: 64) {
            for i in 0..<16 {
                let j = chunkStart + i * 4
                w[i] = (UInt32(msg[j]) << 24) | (UInt32(msg[j + 1]) << 16)
                    | (UInt32(msg[j + 2]) << 8) | UInt32(msg[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        var out: [UInt8] = []
        for v in h {
            out.append(UInt8((v >> 24) & 0xff))
            out.append(UInt8((v >> 16) & 0xff))
            out.append(UInt8((v >> 8) & 0xff))
            out.append(UInt8(v & 0xff))
        }
        return out
    }
}
