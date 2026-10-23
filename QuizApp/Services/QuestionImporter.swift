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
case.empty:
return "文件里没有读到题目"
case.badFormat(let msg):
return "格式不对：" + msg
}
}
}

// 题库导入：JSON 和 CSV 两种都认，题库格式她自己定，两种格式任选其一
enum QuestionImporter {

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
let letters = (r.answers?? [r.answer?? ""])
.joined()
.uppercased()
.filter { allLetterChars.contains($0)}
let unique = Array(Set(letters)).sorted()
if unique.count > 1 {
return try dtoMulti(stem: r.stem, options: r.options,
answerLetters: unique.map { String($0)},
explanation: r.explanation?? "", line: i + 1)
}
return try dto(stem: r.stem, options: r.options,
answerLetter: String(unique.first?? " "),
explanation: r.explanation?? "", line: i + 1)
}
}

// CSV 长这样（第一行是表头，别删）：
// 题干,选项A,选项B,选项C,选项D,答案,解析
// 也可以多一列选项E：题干,选项A,选项B,选项C,选项D,选项E,答案,解析
static func fromCSV(_ text: String) throws -> [QuestionDTO] {
let rows = parseCSV(text)
guard rows.count >= 2 else { throw ImportError.empty}
return try rows.dropFirst().enumerated().compactMap { i, cols in
// 跳过空行
if cols.allSatisfy({ $0.trimmingCharacters(in:.whitespaces).isEmpty}) {
return nil
}
guard cols.count >= 6 else {
throw ImportError.badFormat("第 \(i + 2) 行列数不够（要 6 列：题干,A,B,C,D,答案）")
}
// 8 列及以上按带 E 选项的版式读：题干,A,B,C,D,E,答案,解析
let hasE = cols.count >= 8
let options = hasE? Array(cols[1...5]): Array(cols[1...4])
let answerCol = hasE? cols[6]: cols[5]
let explanation = hasE? cols[7]: (cols.count > 6? cols[6]: "")
// 答案列写一个字母是单选，写 AC 这样连着的是多选
let letters = answerCol.uppercased().filter { allLetterChars.contains($0)}
let unique = Array(Set(letters)).sorted()
if unique.count > 1 {
return try dtoMulti(stem: cols[0], options: options,
answerLetters: unique.map { String($0)},
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
let s = stem.trimmingCharacters(in:.whitespacesAndNewlines)
guard!s.isEmpty else {
throw ImportError.badFormat("第 \(line) 行题干是空的")
}
let opts = options.map { $0.trimmingCharacters(in:.whitespacesAndNewlines)}
guard (2...5).contains(opts.count), opts.allSatisfy({!$0.isEmpty}) else {
throw ImportError.badFormat("第 \(line) 行选项必须是 2 到 5 个非空的（判断题 2 个、单选/多选题 4-5 个）")
}
let letter = answerLetter.trimmingCharacters(in:.whitespacesAndNewlines).uppercased()
guard let idx = allLetters.firstIndex(of: letter), idx < opts.count else {
throw ImportError.badFormat("第 \(line) 行答案必须是 A/B/C/D/E 之一且不能超出选项，写的是「\(answerLetter)」")
}
return QuestionDTO(stem: s, options: opts, answerIndex: idx, explanation: explanation)
}

// 多选题校验：答案至少 2 个字母、不重复、都在选项范围内
static func dtoMulti(stem: String, options: [String], answerLetters: [String],
explanation: String, line: Int) throws -> QuestionDTO {
let s = stem.trimmingCharacters(in:.whitespacesAndNewlines)
guard!s.isEmpty else {
throw ImportError.badFormat("第 \(line) 行题干是空的")
}
let opts = options.map { $0.trimmingCharacters(in:.whitespacesAndNewlines)}
guard (2...5).contains(opts.count), opts.allSatisfy({!$0.isEmpty}) else {
throw ImportError.badFormat("第 \(line) 行选项必须是 2 到 5 个非空的")
}
var indices: [Int] = []
for l in answerLetters {
let u = l.trimmingCharacters(in:.whitespacesAndNewlines).uppercased()
guard let idx = allLetters.firstIndex(of: u), idx < opts.count else {
throw ImportError.badFormat("第 \(line) 行多选答案「\(l)」不对")
}
if!indices.contains(idx) { indices.append(idx)}
}
guard indices.count >= 2 else {
throw ImportError.badFormat("第 \(line) 行多选题答案至少要有 2 个")
}
return QuestionDTO(stem: s, options: opts, answerIndex: indices.sorted()[0],
explanation: explanation, isMulti: true,
answerIndices: indices.sorted())
}

// OCR 常见误认先归一化：全角方括号 ［］、全角字母 Ａ-Ｅ 都换成半角
static func normalize(_ rawText: String) -> String {
var text = rawText
.replacingOccurrences(of: "［", with: "[")
.replacingOccurrences(of: "］", with: "]")
for (i, full) in ["Ａ", "Ｂ", "Ｃ", "Ｄ", "Ｅ"].enumerated() {
text = text.replacingOccurrences(of: full, with: allLetters[i])
}
return text
}

// 一道题在原文里的切块：题型标记（有的话）+ 题号之后的正文 + 原文整块（给 AI 看）
struct RawBlock {
var typeHint: String? // 单选 / 多选 / 判断 / 填空
var body: String // 题号标记之后的正文
var raw: String // 原文整块（含题号标记）
}

// 按题号切块：认 1. / 1、/（1）/ [1] / [1][单选] / [1](单选) 这几种开头
static func splitBlocks(_ rawText: String) -> [RawBlock] {
let text = normalize(rawText)
let ns = text as NSString
guard let startRe = try? NSRegularExpression(
        pattern: "(?m)^[ \\t]*(?:[\\[\u{3010}](\\d{1,4})[\\]\u{3011}][ \\t]*(?:[\\[\u{3010}\\(（](单选|多选|判断|填空)[\\]\u{3011}\\)）])?|(\\d{1,4})[ \\t]*[.、．)）]|[\\(（](\\d{1,4})[\\)）])[ \\t]*")
else { return []}
let starts = startRe.matches(in: text, range: NSRange(location: 0, length: ns.length))
return starts.enumerated().map { bi, m in
let blockEnd = bi + 1 < starts.count? starts[bi + 1].range.location: ns.length
let raw = ns.substring(with: NSRange(location: m.range.location,
length: blockEnd - m.range.location))
let body = ns.substring(with: NSRange(location: m.range.upperBound,
length: blockEnd - m.range.upperBound))
let hint = m.range(at: 2).location!= NSNotFound
? ns.substring(with: m.range(at: 2)): nil
return RawBlock(typeHint: hint, body: body, raw: raw)
}
}

// 文字版题库：PDF / Word / txt 里提取出的文字都走这个解析器。认这种最常见的排版：
// [1](单选) 题干（可以占好几行）
// A. 选项一 B. 选项二 （选项一行一个、或几个挤一行，都行；最多到 E）
// C. 选项三
// 答案：B（多选写 答案：BCDE）
// 解析：可有可无
// 答案也可以写成题干末尾的（B）这种形式。
// 宽容版解析：坏题跳过并记下是第几道，不因一道坏题整份失败（图片识别来源尤其需要）
static func parseFormattedText(_ rawText: String) throws
-> (dtos: [QuestionDTO], skipped: [Int], blocks: Int) {
let blocks = splitBlocks(rawText)
guard!blocks.isEmpty else {
throw ImportError.badFormat("没找到题号（一行一道、题号开头的格式），看看填写说明里的文字版模板")
}
var dtos: [QuestionDTO] = []
var skipped: [Int] = []
for (bi, b) in blocks.enumerated() {
do {
dtos.append(try parseBlock(b.body, index: bi, typeHint: b.typeHint))
} catch {
skipped.append(bi + 1)
}
}
return (dtos, skipped, blocks.count)
}

static func fromFormattedText(_ text: String) throws -> [QuestionDTO] {
let r = try parseFormattedText(text)
if r.dtos.isEmpty {
throw ImportError.badFormat("一道题都没认出来，看看填写说明里的文字版模板")
}
return r.dtos
}

private static func parseBlock(_ rawBlock: String, index bi: Int,
typeHint: String?) throws -> QuestionDTO {
var block = rawBlock

// 先抠答案：答案：B / B；多选写成 答案：BCDE，抠出全部字母
var answerLetters: [String] = []
if let am = firstMatch("(?:\u{3010})?(?:答案|正确答案)(?:\u{3011})?[ \t]*[:：]?[ \t]*([ABCDE](?:[ \t]*[,，、和]?[ \t]*[ABCDE])*)", in: block) {
let raw = (block as NSString).substring(with: am.range(at: 1))
answerLetters = raw.filter { allLetterChars.contains($0)}.map { String($0)}
block = replace(block, range: am.range, with: "")
}
// 再抠解析：解析：……一直到这道题结束
var explanation = ""
if let em = firstMatch(#"(?:解析|答案解析|试题解析)[ \t]*[:：]"#, in: block) {
let s = (em.range.location + em.range.length)
explanation = ((block as NSString).substring(from: s))
.trimmingCharacters(in:.whitespacesAndNewlines)
block = (block as NSString).substring(to: em.range.location)
}
// 答案没单独写的话，认题干/选项里括号包着的：（B）
if answerLetters.isEmpty,
let am = firstMatch(#"[(（][ \t]*([ABCDE])[ \t]*[)）]"#, in: block) {
answerLetters = [(block as NSString).substring(with: am.range(at: 1))]
block = replace(block, range: am.range, with: "")
}
guard!answerLetters.isEmpty else {
throw ImportError.badFormat("第 \(bi + 1) 题没找到答案（要写「答案：B」或在题干后标（B））")
}
// 去重保序
var seen = Set<String>()
answerLetters = answerLetters.filter { seen.insert($0).inserted}

// 抠选项：找 A. B. C. D. E. 标记，标记之间就是选项内容。
// 理想情况字母从 A 起严格连续；OCR 串行时可能多出重复/乱序标记，
// 这时贪心只收「下一个该出现的字母」，把串掉的标记丢掉，别整道扔。
let optRe = try NSRegularExpression(pattern: #"([ABCDE])[ \t]*[.、．:：]"#)
let bns = block as NSString
let allOpts = optRe.matches(in: block, range: NSRange(location: 0, length: bns.length))
var opts: [NSTextCheckingResult] = []
for m in allOpts {
let letter = bns.substring(with: m.range(at: 1))
if letter == allLetters[opts.count] { opts.append(m)}
}
let n = opts.count
guard (2...5).contains(n) else {
throw ImportError.badFormat("第 \(bi + 1) 题选项没凑齐（单选要 A、B、C、D，多选可到 E，判断要 A、B）")
}
var stem = bns.substring(to: opts[0].range.location)
.trimmingCharacters(in:.whitespacesAndNewlines)
// 题型标记要是没被题号正则吃掉（比如单独占了一行），从题干开头摘掉
            if let tm = firstMatch("^[\\[\u{3010}\\(（](?:单选|多选|判断|填空)[\\]\u{3011}\\)）][ \\t]*", in: stem) {
stem = replace(stem, range: tm.range, with: "")
.trimmingCharacters(in:.whitespacesAndNewlines)
}
var options: [String] = []
for i in 0..<n {
let s = opts[i].range.upperBound
let e = i + 1 < n? opts[i + 1].range.location: bns.length
options.append(bns.substring(with: NSRange(location: s, length: e - s))
.trimmingCharacters(in:.whitespacesAndNewlines))
}
// 定题型：判断题永远是单选类（2 个选项）；答案字母超过 1 个就是多选；
// 题型标记写了多选、但只抠到 1 个答案字母时按单选收，别把题扔了。
if typeHint == "判断" {
return try dto(stem: stem, options: options, answerLetter: answerLetters[0],
explanation: explanation, line: bi + 1)
}
if answerLetters.count > 1 {
return try dtoMulti(stem: stem, options: options,
answerLetters: answerLetters,
explanation: explanation, line: bi + 1)
}
return try dto(stem: stem, options: options, answerLetter: answerLetters[0],
explanation: explanation, line: bi + 1)
}

private static func firstMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
guard let re = try? NSRegularExpression(pattern: pattern) else { return nil}
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
if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1}
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
