import Foundation
import SwiftData

// 一道题：题干 + 4 个选项 + 答案 + 解析，外加刷题统计
// 错题本没有单独建表：就是"答错过、还没连续答对 requiredStreak 次"的题
@Model
final class Question {
    var id: UUID
    var stem: String        // 题干
    var options: [String]   // 4 个选项，顺序固定
    var answerIndex: Int    // 正确答案是第几个（0-3，对应 A-D）
    var explanation: String // 解析，可空
    var deckName: String    // 哪次导入的题库
    var isMulti: Bool       // 多选题（答案不止一个）
    var answerIndices: [Int] // 多选题的正确答案集合（单选时为空，用 answerIndex）
    var isFavorite: Bool    // 收藏夹

    // 刷题统计
    var totalAttempts: Int   // 刷过几次
    var correctAttempts: Int // 答对几次
    var wrongCount: Int      // 累计答错几次
    var masterStreak: Int    // 在错题本里连续答对几次（只在错题本重做时累积）

    // 她定的规矩（2026-10-23）：错题本里的题做正确 2 次才移出
    static let requiredStreak = 2

    var isInWrongBank: Bool {
        wrongCount > 0 && masterStreak < Self.requiredStreak
    }

    // 正确答案的字母表示：单选一个字母，多选如「A、C」
    var correctAnswerText: String {
        let letters = ["A", "B", "C", "D"]
        if isMulti {
            return answerIndices.sorted().map { letters[$0] }.joined(separator: "、")
        }
        return letters[answerIndex]
    }

    init(stem: String, options: [String], answerIndex: Int,
         explanation: String = "", deckName: String = "默认题库",
         isMulti: Bool = false, answerIndices: [Int] = []) {
        self.id = UUID()
        self.stem = stem
        self.options = options
        self.answerIndex = answerIndex
        self.explanation = explanation
        self.deckName = deckName
        self.isMulti = isMulti
        self.answerIndices = answerIndices
        self.isFavorite = false
        self.totalAttempts = 0
        self.correctAttempts = 0
        self.wrongCount = 0
        self.masterStreak = 0
    }
}
