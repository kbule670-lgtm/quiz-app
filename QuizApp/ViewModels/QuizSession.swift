import Foundation

// 一次刷题会话：管题目顺序、判分、写统计
// 错题本重做也是它——只是传进来的题不一样（调用方把错题过滤好再传）
@Observable
final class QuizSession: Identifiable {
    let id = UUID()
    private(set) var questions: [Question] = []
    private(set) var order: [Int] = []   // 本轮题目顺序（存的是下标）
    private(set) var cursor = 0
    private(set) var selectedIndex: Int? = nil
    private(set) var answered = false
    private(set) var correctCount = 0

    var total: Int { order.count }
    var isFinished: Bool { cursor >= order.count }
    var current: Question? {
        guard cursor < order.count else { return nil }
        return questions[order[cursor]]
    }

    func start(questions: [Question], shuffle: Bool) {
        self.questions = questions
        self.order = Array(questions.indices)
        if shuffle { self.order.shuffle() }
        self.cursor = 0
        self.correctCount = 0
        resetTurn()
    }

    func restart() {
        order.shuffle()
        cursor = 0
        correctCount = 0
        resetTurn()
    }

    private func resetTurn() {
        selectedIndex = nil
        answered = false
    }

    // 选了一个选项：判分 + 写统计（SwiftData 会自动持久化）
    func choose(_ i: Int) {
        guard let q = current, !answered else { return }
        selectedIndex = i
        answered = true
        q.totalAttempts += 1
        if i == q.answerIndex {
            correctCount += 1
            q.correctAttempts += 1
            q.masterStreak += 1      // 连续答对 +1
        } else {
            q.wrongCount += 1
            q.masterStreak = 0       // 答错就清零，重新攒
        }
    }

    func next() {
        cursor += 1
        resetTurn()
    }
}
