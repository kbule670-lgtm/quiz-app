import Foundation

// 一次刷题会话：管题目顺序、判分、写统计
// 错题本重做也是它——只是传进来的题不一样，且 mastery=true：
// 只有在错题本里答对才累积 masterStreak，攒满 requiredStreak(2) 次移出（她的规矩）
@Observable
final class QuizSession: Identifiable {
    let id = UUID()
    private(set) var questions: [Question] = []
    private(set) var order: [Int] = []   // 本轮题目顺序（存的是下标）
    private(set) var cursor = 0
    private(set) var selectedIndex: Int? = nil   // 单选选了哪个
    private(set) var selectedSet: Set<Int> = []  // 多选选了哪些
    private(set) var answered = false
    private(set) var correctCount = 0
    private(set) var mastery = false     // 本轮是不是错题本重做

    var total: Int { order.count }
    var isFinished: Bool { cursor >= order.count }
    var current: Question? {
        guard cursor < order.count else { return nil }
        return questions[order[cursor]]
    }

    func start(questions: [Question], shuffle: Bool, mastery: Bool = false) {
        self.questions = questions
        self.order = Array(questions.indices)
        if shuffle { self.order.shuffle() }
        self.cursor = 0
        self.correctCount = 0
        self.mastery = mastery
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
        selectedSet = []
        answered = false
    }

    // 单选：点一个就判分
    func choose(_ i: Int) {
        guard let q = current, !answered, !q.isMulti else { return }
        selectedIndex = i
        grade(correct: i == q.answerIndex)
    }

    // 多选：点选项只是勾选/取消，点「提交」才判分
    func toggle(_ i: Int) {
        guard let q = current, !answered, q.isMulti else { return }
        if selectedSet.contains(i) { selectedSet.remove(i) } else { selectedSet.insert(i) }
    }

    func submitMulti() {
        guard let q = current, !answered, q.isMulti, !selectedSet.isEmpty else { return }
        grade(correct: selectedSet == Set(q.answerIndices))
    }

    private func grade(correct: Bool) {
        guard let q = current else { return }
        answered = true
        q.totalAttempts += 1
        if correct {
            correctCount += 1
            q.correctAttempts += 1
            if mastery { q.masterStreak += 1 }  // 只在错题本里攒移出进度
        } else {
            q.wrongCount += 1
            q.masterStreak = 0                 // 答错清零，重新攒
        }
    }

    func next() {
        cursor += 1
        resetTurn()
    }
}
