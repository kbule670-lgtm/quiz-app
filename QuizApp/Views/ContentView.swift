import SwiftUI
import SwiftData

// 首页：三个 Tab —— 刷题 / 错题本 / 题库
struct ContentView: View {
    @Query private var questions: [Question]
    @State private var shuffle = true
    @State private var wrongOnly = false
    @State private var session: QuizSession?

    var wrongQuestions: [Question] { questions.filter(\.isInWrongBank) }

    var body: some View {
        TabView {
            quizTab
                .tabItem { Label("刷题", systemImage: "pencil.circle") }
            WrongBankView(startQuiz: startQuiz)
                .tabItem { Label("错题本", systemImage: "xmark.circle") }
            ImportView()
                .tabItem { Label("题库", systemImage: "tray.full") }
        }
        .fullScreenCover(item: $session) { s in
            QuizView(session: s)
        }
    }

    private var quizTab: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if questions.isEmpty {
                    ContentUnavailableView(
                        "题库是空的",
                        systemImage: "tray",
                        description: Text("去「题库」页导入题库，或先载入示例题试试手")
                    )
                } else {
                    let pool = wrongOnly ? wrongQuestions : questions
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("随机顺序", isOn: $shuffle)
                        Toggle("只刷错题本（\(wrongQuestions.count) 道）", isOn: $wrongOnly)
                    }
                    Button("开始刷题（\(pool.count) 道）") {
                        startQuiz(pool, shuffle: shuffle)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(pool.isEmpty)
                    Text("题库共 \(questions.count) 道")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle("刷题")
        }
    }

    private func startQuiz(_ pool: [Question], shuffle: Bool) {
        let s = QuizSession()
        s.start(questions: pool, shuffle: shuffle)
        session = s
    }
}
