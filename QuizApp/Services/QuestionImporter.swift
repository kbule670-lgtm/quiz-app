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
    private static func dto(stem: String, options: [String], answerLetter: String,
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
