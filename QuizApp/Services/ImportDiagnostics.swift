import Foundation

// 导入诊断（8.ipa）：把 OCR → 清理 → 切题 → 入库每一步分别计数，
// 题目在哪一步消失就能定位，不再只看最后入库数。
// 本文件只依赖 Foundation，可在本地工具链完整类型检查与跑 harness。

// OCR 的一行：文本 + 页码 + 页内纵坐标比例（Vision boundingBox midY，
// 底边为 0、顶边为 1；文字层 PDF 没有坐标，记 nil，走回退规则）。
struct OCRLine: Codable {
var text: String
var page: Int
var midY: Double?
}

// 逐页存档的单页记录：持久化到沙盒临时文件（每页一个原子写文件）。
// 状态机：ocrDone → cleaned → split → inserted，分开记；
// 「该页有文本」绝不等于「该页已处理完成」，续跑只看 stage。
enum PageStage: String, Codable {
case ocrDone // 仅 OCR 完成（文本已落盘）
case cleaned // 已清理
case split // 已切题
case inserted // 已入库
}

struct OCRPageRecord: Codable {
var page: Int
var text: String
// 逐行坐标（8.ipa 起存）：续跑复用与事后重算都要靠它走真实位置规则；
// 老存档没有这一项时按缺省 [] 解码，调用方回退到按行切分（坐标 nil，走回退规则）。
var lines: [OCRLine] = []
var recognized: Bool // 该页是否识别出有效文字
var cleanerVersion: Int // 清理时用的清理器版本
var stage: PageStage
}

// 清理报告：删了多少行、按哪条规则删的、关键标记清理前后变化
struct CleanupReport {
var removedShortRepeat = 0 // 短行重复删除（旧规则分支）
var removedLongRepeat = 0 // 长行重复删除（旧规则分支）
var removedEdgeRepeat = 0 // 边缘带跨页重复删除（新规则）
var removedFallback = 0 // 无坐标回退规则删除
var judgeCorrectBefore = 0
var judgeCorrectAfter = 0
var judgeWrongBefore = 0
var judgeWrongAfter = 0
var markersBefore = 0
var markersAfter = 0

var removedTotal: Int {
removedShortRepeat + removedLongRepeat + removedEdgeRepeat + removedFallback
}
}

// 导入全链路诊断
struct ImportDiagnostics {
// A. OCR
var ocrPagesDone = 0
var ocrPagesTotal = 0
var blankPages: [Int] = [] // 空白或低字符页（页码从 1 计）
var ocrTotalChars = 0
var ocrMarkerCandidates = 0
var ocrOptionMarkers = 0
var ocrJudgeCorrectLines = 0
var ocrJudgeWrongLines = 0
// B. 清理
var cleanup = CleanupReport()
// C. 切题
var splitCandidates = 0
var splitBlocks = 0
var blocksByType: [String: Int] = [:] // 单选 / 多选 / 判断
var abnormalBlocks = 0
var lowConfidenceBlocks = 0
var unblockedChars = 0 // 第一个题界之前的文本量
// D. 入库（四分口径，互斥）
var insertedRule = 0
var insertedAI = 0
var skippedExisting = 0
var unrecovered = 0
var insertedByType: [String: Int] = [:]
// 题号四段归因（仅普通/智能模式的块后缀路径可精确归因；云端/本地模式只给计数）
var missingByStage: [(stage: String, numbers: [Int])] = []
var numbersContinuous = false

// 质量警告：识别题号候选与最终题块差距过大
var gapWarning: String? {
guard ocrMarkerCandidates > 0, splitBlocks > 0 else { return nil}
if splitBlocks * 5 < ocrMarkerCandidates * 4 {
return "识别到的题目结构与最终可导入题数差异较大，请查看诊断"
}
return nil
}

// 纯文本报告（可复制/分享，不含完整题目内容）
var reportText: String {
var lines: [String] = []
lines.append("")
lines.append("A. OCR：\(ocrPagesDone)/\(ocrPagesTotal) 页，总字符 \(ocrTotalChars)，题号候选 \(ocrMarkerCandidates)，选项标记 \(ocrOptionMarkers)，独立「正确」行 \(ocrJudgeCorrectLines)、「错误」行 \(ocrJudgeWrongLines)")
if !blankPages.isEmpty {
lines.append(" 空白/低字符页：\(blankPages.map(String.init).joined(separator: "、"))")
}
lines.append("B. 清理：删除 \(cleanup.removedTotal) 行（短行重复 \(cleanup.removedShortRepeat)、长行重复 \(cleanup.removedLongRepeat)、边缘带重复 \(cleanup.removedEdgeRepeat)、回退 \(cleanup.removedFallback)）；「正确」行 \(cleanup.judgeCorrectBefore)→\(cleanup.judgeCorrectAfter)、「错误」行 \(cleanup.judgeWrongBefore)→\(cleanup.judgeWrongAfter)；题号候选 \(cleanup.markersBefore)→\(cleanup.markersAfter)")
lines.append("C. 切题：候选 \(splitCandidates)、确认题块 \(splitBlocks)（单选 \(blocksByType["单选"] ??  0)、多选 \(blocksByType["多选"] ??  0)、判断 \(blocksByType["判断"] ??  0)）、异常块 \(abnormalBlocks)、低置信块 \(lowConfidenceBlocks)、未入块文本 \(unblockedChars) 字")
lines.append("D. 入库：普通解析新入 \(insertedRule)、AI 新入 \(insertedAI)、已存在跳过 \(skippedExisting)、未救回 \(unrecovered)")
if !missingByStage.isEmpty {
lines.append(numbersContinuous ? "题号归因（编号连续资料）：": "题号归因（编号不连续，仅疑似提示）：")
for (stage, numbers) in missingByStage where !numbers.isEmpty {
lines.append(" \(stage)：\(numbers.map(String.init).joined(separator: "、"))")
}
}
if let w = gapWarning { lines.append("⚠️ \(w)")}
return lines.joined(separator: "\n")
}
}

// 清理规则版本：1 = 7.ipa 旧规则（按全书出现次数删短行，无白名单）；
// 2 = 8.ipa 新规则（页面位置＋跨页比例＋语义保护，无坐标时回退旧规则＋白名单）。
enum CleanerVersion {
static let legacy = 1
static let current = 2
}

enum ImportCleaner {

// 语义保护：这些行永不删除（新规则与回退规则通用；旧规则复现列除外）。
// 「正确」「错误」是判断题选项，8.ipa 起加入保护（7.ipa 旧规则复现时不加，
// 否则复现不出当时的误删——见机制实证）。
static func isSemanticallyProtected(_ trimmed: String) -> Bool {
if trimmed == "正确" || trimmed == "错误" { return true}
if trimmed.hasPrefix("答案") || trimmed.hasPrefix("解析") { return true}
if let f = trimmed.first,
"ABCDE".contains(f) || f.isNumber || f == "[" || f == "【" {
return true
}
return false
}

// 7.ipa 旧规则原样复现（无白名单），供对照实验「原清理规则」列使用。
// removeShortRepeat = false 时为「关闭重复短行删除」列。
static func legacyClean(lines: [String], removeShortRepeat: Bool)
-> (lines: [String], report: CleanupReport) {
var counts: [String: Int] = [:]
for l in lines {
let t = l.trimmingCharacters(in:.whitespaces)
if !t.isEmpty { counts[t, default: 0] += 1}
}
var report = CleanupReport()
report.judgeCorrectBefore = lines.filter { $0.trimmingCharacters(in:.whitespaces) == "正确"}.count
report.judgeWrongBefore = lines.filter { $0.trimmingCharacters(in:.whitespaces) == "错误"}.count
let kept = lines.filter { raw in
let t = raw.trimmingCharacters(in:.whitespaces)
let c = counts[t] ??  0
if t.hasPrefix("答案") || t.hasPrefix("解析") { return true}
if let f = t.first, "ABCDE".contains(f) || f.isNumber || f == "[" || f == "【" {
return true
}
if removeShortRepeat, t.count <= 12, c >= 4 {
report.removedShortRepeat += 1
return false
}
// 长分支只管 13-40 字行：短行只由短分支管，否则「关闭重复短行删除」后短行仍会被长分支删掉，对照实验失真。
if t.count > 12, t.count <= 40, c >= 20 {
report.removedLongRepeat += 1
return false
}
return true
}
report.judgeCorrectAfter = kept.filter { $0.trimmingCharacters(in:.whitespaces) == "正确"}.count
report.judgeWrongAfter = kept.filter { $0.trimmingCharacters(in:.whitespaces) == "错误"}.count
return (kept, report)
}

// 8.ipa 新规则：页面位置＋跨页比例＋语义保护。
// 边缘带：页内纵坐标顶部 8%（midY ≥ 0.92）或底部 8%（midY ≤ 0.08）。
// 删除候选：该行出现在 ≥20% 的页面，且 ≥80% 的出现位于边缘带，且长度 ≤40；
// 语义保护永远优先；无坐标的行退回旧规则＋白名单（报告里记为回退删除）。
static func metaClean(lines: [OCRLine], totalPages: Int)
-> (lines: [OCRLine], report: CleanupReport) {
var report = CleanupReport()
report.judgeCorrectBefore = lines.filter { $0.text.trimmingCharacters(in:.whitespaces) == "正确"}.count
report.judgeWrongBefore = lines.filter { $0.text.trimmingCharacters(in:.whitespaces) == "错误"}.count
// 每行文本的出现页集合与边缘带出现次数
var pagesOf: [String: Set<Int>] = [:]
var edgeHits: [String: Int] = [:]
var totalHits: [String: Int] = [:]
for l in lines {
let t = l.text.trimmingCharacters(in:.whitespaces)
guard !t.isEmpty else { continue}
pagesOf[t, default: []].insert(l.page)
totalHits[t, default: 0] += 1
if let y = l.midY, y >= 0.92 || y <= 0.08 {
edgeHits[t, default: 0] += 1
}
}
let pageThreshold = max(1, Int(Double(totalPages) * 0.2))
var kept: [OCRLine] = []
for l in lines {
let t = l.text.trimmingCharacters(in:.whitespaces)
if t.isEmpty { kept.append(l); continue}
if isSemanticallyProtected(t) { kept.append(l); continue}
guard l.midY != nil else {
// 无坐标回退：旧规则＋白名单（白名单已在语义保护里）
let c = totalHits[t] ??  0
if t.count <= 12, c >= 4 {
report.removedFallback += 1
continue
}
if t.count > 12, t.count <= 40, c >= 20 {
report.removedFallback += 1
continue
}
kept.append(l)
continue
}
let distinctPages = pagesOf[t]?.count ??  0
let edge = edgeHits[t] ??  0
let total = totalHits[t] ??  0
if t.count <= 40, distinctPages >= pageThreshold, total > 0,
Double(edge) >= Double(total) * 0.8 {
report.removedEdgeRepeat += 1
continue
}
kept.append(l)
}
report.judgeCorrectAfter = kept.filter { $0.text.trimmingCharacters(in:.whitespaces) == "正确"}.count
report.judgeWrongAfter = kept.filter { $0.text.trimmingCharacters(in:.whitespaces) == "错误"}.count
return (kept, report)
}
}

// 重算路径（正式功能）：同一份已保存 OCR 原文，用指定清理规则重跑
// 清理 → 切题 → 计数，只产出诊断计数，绝不写题库。
// 三组必须用同一份原文：legacy7（复现 7.ipa 规则）、legacyNoShortRepeat
// （关闭重复短行删除）、meta8（8.ipa 新规则）。
enum CleanRule {
case legacy7
case legacyNoShortRepeat
case meta8
}

struct RecomputeResult {
var ruleName: String
var judgeSuccess = 0
var multiSuccess = 0
var singleSuccess = 0
var correctDeleted = 0
var wrongDeleted = 0
var abnormalBlocks = 0
var insertableCount = 0
var blocks = 0
var splitEvents: [Int] = [] // 启发式劈开发生的块号（无误劈核查用）
var removedTotal = 0
}

enum ImportRecompute {

static func run(ocrText: String, rule: CleanRule) -> RecomputeResult {
let rawLines = ocrText.components(separatedBy: "\n")
let cleanedText: String
var report = CleanupReport()
switch rule {
case.legacy7:
let r = ImportCleaner.legacyClean(lines: rawLines, removeShortRepeat: true)
cleanedText = r.lines.joined(separator: "\n")
report = r.report
case.legacyNoShortRepeat:
let r = ImportCleaner.legacyClean(lines: rawLines, removeShortRepeat: false)
cleanedText = r.lines.joined(separator: "\n")
report = r.report
case.meta8:
// 纯文本重算没有坐标：全部行走回退规则＋白名单（与 App 内文字层路径一致）
let ocrLines = rawLines.enumerated().map {
OCRLine(text: $0.element, page: 0, midY: nil)
}
let r = ImportCleaner.metaClean(lines: ocrLines, totalPages: 1)
cleanedText = r.lines.map(\.text).joined(separator: "\n")
report = r.report
}
var result = RecomputeResult(ruleName: "\(rule)")
result.correctDeleted = report.judgeCorrectBefore - report.judgeCorrectAfter
result.wrongDeleted = report.judgeWrongBefore - report.judgeWrongAfter
result.removedTotal = report.removedTotal
let parsed = QuestionImporter.parseDetailed(cleanedText)
result.blocks = parsed.blocks.count
result.abnormalBlocks = parsed.skipped.count
+ parsed.items.filter(\.suspect).count
for item in parsed.items {
if item.dto.isMulti {
result.multiSuccess += 1
} else if item.dto.options == ["正确", "错误"] {
result.judgeSuccess += 1
} else {
result.singleSuccess += 1
}
}
result.insertableCount = parsed.items.count
result.splitEvents = parsed.items.filter { $0.subIndex > 0}.map(\.blockIndex)
return result
}

// 带坐标的重算（App 内 OCR 路径用）：meta8 走真实位置规则
static func runWithLines(_ ocrLines: [OCRLine], totalPages: Int, rule: CleanRule)
-> RecomputeResult {
switch rule {
case.meta8:
let r = ImportCleaner.metaClean(lines: ocrLines, totalPages: totalPages)
return finish(cleanedLines: r.lines.map(\.text), report: r.report, rule: rule)
default:
return run(ocrText: ocrLines.map(\.text).joined(separator: "\n"), rule: rule)
}
}

private static func finish(cleanedLines: [String], report: CleanupReport, rule: CleanRule)
-> RecomputeResult {
var result = RecomputeResult(ruleName: "\(rule)")
result.correctDeleted = report.judgeCorrectBefore - report.judgeCorrectAfter
result.wrongDeleted = report.judgeWrongBefore - report.judgeWrongAfter
result.removedTotal = report.removedTotal
let parsed = QuestionImporter.parseDetailed(cleanedLines.joined(separator: "\n"))
result.blocks = parsed.blocks.count
result.abnormalBlocks = parsed.skipped.count
+ parsed.items.filter(\.suspect).count
for item in parsed.items {
if item.dto.isMulti {
result.multiSuccess += 1
} else if item.dto.options == ["正确", "错误"] {
result.judgeSuccess += 1
} else {
result.singleSuccess += 1
}
}
result.insertableCount = parsed.items.count
result.splitEvents = parsed.items.filter { $0.subIndex > 0}.map(\.blockIndex)
return result
}
}
