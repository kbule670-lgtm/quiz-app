import Foundation

// 导入前的数据形态：跟 Question 一样，只是还没进数据库
struct QuestionDTO {
    var stem: String
    var options: [String]  // 必须 4 个
    var answerIndex: Int    // 0-3
    var explanation: String
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

// 题库导入：JSON 和 CSV 两种都认，题库格式她自己定，两种格式任选其一
enum QuestionImporter {

    // JSON 长这样：
    // [{"stem":"题干","options":["A项","B项","C项","D项"],"answer":"B","explanation":"解析，可空"}]
    // 答案写 A/B/C/D 字母，对她最直觉
    static func fromJSON(_ data: Data) throws -> [QuestionDTO] {
        struct Raw: Decodable {
            var stem: String
            var options: [String]
            var answer: String
            var explanation: String?
        }
        let raws = try JSONDecoder().decode([Raw].self, from: data)
        return try raws.enumerated().map { i, r in
            try dto(stem: r.stem, options: r.options, answerLetter: r.answer,
                    explanation: r.explanation ?? "", line: i + 1)
        }
    }

    // CSV 长这样（第一行是表头，别删）：
    // 题干,选项A,选项B,选项C,选项D,答案,解析
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
            return try dto(stem: cols[0], options: Array(cols[1...4]),
                           answerLetter: cols[5],
                           explanation: cols.count > 6 ? cols[6] : "",
                           line: i + 2)
        }
    }

    // 统一校验：题干非空、4 个非空选项、答案是 A-D 之一
    static func dto(stem: String, options: [String], answerLetter: String,
                            explanation: String, line: Int) throws -> QuestionDTO {
        let s = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else {
            throw ImportError.badFormat("第 \(line) 行题干是空的")
        }
        let opts = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard opts.count == 4, opts.allSatisfy({ !$0.isEmpty }) else {
            throw ImportError.badFormat("第 \(line) 行选项必须是 4 个非空的")
        }
        let letter = answerLetter.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let idx = ["A", "B", "C", "D"].firstIndex(of: letter) else {
            throw ImportError.badFormat("第 \(line) 行答案必须是 A/B/C/D，写的是「\(answerLetter)」")
        }
        return QuestionDTO(stem: s, options: opts, answerIndex: idx, explanation: explanation)
    }

    // 文字版题库：PDF / Word / txt 里提取出的文字都走这个解析器。认这种最常见的排版：
    // 1. 题干（可以占好几行）
    // A. 选项一  B. 选项二      （选项一行一个、或几个挤一行，都行）
    // C. 选项三
    // D. 选项四
    // 答案：B
    // 解析：可有可无
    // 答案也可以写成题干末尾的（B）这种形式。
    static func fromFormattedText(_ text: String) throws -> [QuestionDTO] {
        let ns = text as NSString
        // 按"行首的题号"切块
        let startRe = try NSRegularExpression(pattern: #"(?m)^[ \t]*\d{1,4}[ \t]*[.、．)）][ \t]*"#)
        let starts = startRe.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !starts.isEmpty else {
            throw ImportError.badFormat("没找到题号（一行一道、题号开头的格式），看看填写说明里的文字版模板")
        }
        var dtos: [QuestionDTO] = []
        for (bi, m) in starts.enumerated() {
            let from = m.range.upperBound
            let to = bi + 1 < starts.count ? starts[bi + 1].range.location : ns.length
            var block = ns.substring(with: NSRange(location: from, length: to - from))

            // 先抠答案：答案：B / 【答案】B
            var answerLetter: String?
            if let am = firstMatch(#"(?:【)?(?:答案|正确答案)(?:】)?[ \t]*[:：]?[ \t]*([ABCD])"#, in: block) {
                answerLetter = (block as NSString).substring(with: am.range(at: 1))
                block = replace(block, range: am.range, with: "")
            }
            // 再抠解析：解析：……一直到这道题结束
            var explanation = ""
            if let em = firstMatch(#"(?:解析|答案解析|试题解析)[ \t]*[:：]"#, in: block) {
                let s = (em.range.location + em.range.length)
                explanation = ((block as NSString).substring(from: s))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                block = (block as NSString).substring(to: em.range.location)
            }
            // 答案没单独写的话，认题干/选项里括号包着的：（B）
            if answerLetter == nil,
               let am = firstMatch(#"[(（][ \t]*([ABCD])[ \t]*[)）]"#, in: block) {
                answerLetter = (block as NSString).substring(with: am.range(at: 1))
                block = replace(block, range: am.range, with: "")
            }
            guard let ans = answerLetter else {
                throw ImportError.badFormat("第 \(bi + 1) 题没找到答案（要写「答案：B」或在题干后标（B））")
            }
            // 抠选项：找 A. B. C. D. 四个标记，标记之间就是选项内容
            let optRe = try NSRegularExpression(pattern: #"([ABCD])[ \t]*[.、．:：]"#)
            let bns = block as NSString
            let opts = optRe.matches(in: block, range: NSRange(location: 0, length: bns.length))
            guard opts.count == 4,
                  (0..<4).allSatisfy({ bns.substring(with: opts[$0].range(at: 1)) == ["A", "B", "C", "D"][$0] })
            else {
                throw ImportError.badFormat("第 \(bi + 1) 题没凑齐 A、B、C、D 四个选项")
            }
            let stem = bns.substring(to: opts[0].range.location)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var options: [String] = []
            for i in 0..<4 {
                let s = opts[i].range.upperBound
                let e = i + 1 < 4 ? opts[i + 1].range.location : bns.length
                options.append(bns.substring(with: NSRange(location: s, length: e - s))
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }
            dtos.append(try dto(stem: stem, options: options, answerLetter: ans,
                                explanation: explanation, line: bi + 1))
        }
        return dtos
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
