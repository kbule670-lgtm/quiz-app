import SwiftUI
import SwiftData

// 首页：四个 Tab —— 刷题 / 错题本 / 收藏 / 题库
// 她的规矩：题目全部随机顺序；单选（含判断）和多选是两个大类
struct ContentView: View {
    @Query private var questions: [Question]
    @State private var wrongOnly = false
    @State private var session: QuizSession?

    var wrongQuestions: [Question] { questions.filter(\.isInWrongBank) }
    var singlePool: [Question] { questions.filter { !$0.isMulti } }
    var multiPool: [Question] { questions.filter(\.isMulti) }

    var body: some View {
        TabView {
            quizTab
                .tabItem { Label("刷题", systemImage: "pencil.circle") }
            WrongBankView(startQuiz: { pool, mastery in startQuiz(pool, mastery: mastery) })
                .tabItem { Label("错题本", systemImage: "xmark.circle") }
            FavoritesView(startQuiz: { pool, mastery in startQuiz(pool, mastery: mastery) })
                .tabItem { Label("收藏", systemImage: "star") }
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
                    let base = wrongOnly ? wrongQuestions : questions
                    let singles = base.filter { !$0.isMulti }
                    let multis = base.filter(\.isMulti)
                    Toggle("只刷错题本（\(wrongQuestions.count) 道）", isOn: $wrongOnly)
                    Button("随机刷全部（\(base.count) 道）") {
                        startQuiz(base, mastery: wrongOnly)
                    }
                    .primaryGlassButton()
                    .controlSize(.large)
                    .disabled(base.isEmpty)
                    HStack(spacing: 12) {
                        Button("单选（含判断）\(singles.count) 道") {
                            startQuiz(singles, mastery: wrongOnly)
                        }
                        .primaryGlassButton()
                        .disabled(singles.isEmpty)
                        Button("多选 \(multis.count) 道") {
                            startQuiz(multis, mastery: wrongOnly)
                        }
                        .primaryGlassButton()
                        .disabled(multis.isEmpty)
                    }
                    Text("题库共 \(questions.count) 道：单选（含判断）\(singlePool.count) 道、多选 \(multiPool.count) 道")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle("刷题")
        }
    }

    private func startQuiz(_ pool: [Question], mastery: Bool) {
        let s = QuizSession()
        s.start(questions: pool, shuffle: true, mastery: mastery)
        session = s
    }
}
