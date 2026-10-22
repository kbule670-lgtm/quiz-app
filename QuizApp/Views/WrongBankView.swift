import SwiftUI
import SwiftData

// 错题本：列表 + 一键重做；做对一次（requiredStreak）就自动移出
struct WrongBankView: View {
    @Query private var questions: [Question]
    var startQuiz: ([Question], Bool) -> Void

    private let letters = ["A", "B", "C", "D"]
    var wrong: [Question] { questions.filter(\.isInWrongBank) }

    var body: some View {
        NavigationStack {
            if wrong.isEmpty {
                ContentUnavailableView(
                    "错题本是空的",
                    systemImage: "checkmark.circle",
                    description: Text("答错的题会自动进来，重做到对就移出")
                )
                .navigationTitle("错题本")
            } else {
                List {
                    Section {
                        Button("重做错题本（\(wrong.count) 道，随机顺序）") {
                            startQuiz(wrong, true)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Section("错题列表") {
                        ForEach(wrong) { q in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(q.stem).lineLimit(2)
                                Text("累计错 \(q.wrongCount) 次 · 正确答案 \(letters[q.answerIndex])")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .navigationTitle("错题本")
            }
        }
    }
}
