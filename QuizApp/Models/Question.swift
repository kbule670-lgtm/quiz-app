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

    // 刷题统计
    var totalAttempts: Int   // 刷过几次
    var correctAttempts: Int // 答对几次
    var wrongCount: Int      // 累计答错几次
    var masterStreak: Int    // 当前连续答对几次

    // 连续答对几次算掌握、移出错题本。
    // 她要是想要"对 2 次才移出"，把下面这个 1 改成 2，一行搞定。
    static let requiredStreak = 1

    var isInWrongBank: Bool {
        wrongCount > 0 && masterStreak < Self.requiredStreak
    }

    init(stem: String, options: [String], answerIndex: Int,
         explanation: String = "", deckName: String = "默认题库") {
        self.id = UUID()
        self.stem = stem
        self.options = options
        self.answerIndex = answerIndex
        self.explanation = explanation
        self.deckName = deckName
        self.totalAttempts = 0
        self.correctAttempts = 0
        self.wrongCount = 0
        self.masterStreak = 0
    }
}
