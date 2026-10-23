import SwiftUI
import SwiftData

// 收藏夹：所有题在刷题时点星标就能收进来，再点一次取消；这里能集中随机刷收藏
struct FavoritesView: View {
    @Query private var questions: [Question]
    var startQuiz: ([Question], Bool) -> Void

    var favorites: [Question] { questions.filter(\.isFavorite) }

    var body: some View {
        NavigationStack {
            if favorites.isEmpty {
                ContentUnavailableView(
                    "收藏夹是空的",
                    systemImage: "star",
                    description: Text("刷题时点右上角的星星，就能把题目收藏到这里")
                )
                .navigationTitle("收藏")
            } else {
                List {
                    Section {
                        Button("随机刷收藏（\(favorites.count) 道）") {
                            startQuiz(favorites, false)
                        }
                        .primaryGlassButton()
                    }
                    Section("收藏的题") {
                        ForEach(favorites) { q in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(q.stem).lineLimit(2)
                                Text("\(q.isMulti ? "多选" : (q.options.count == 2 ? "判断" : "单选")) · 正确答案 \(q.correctAnswerText)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .swipeActions(edge: .trailing) {
                                Button("取消收藏") { q.isFavorite = false }
                                    .tint(.orange)
                            }
                        }
                    }
                }
                .navigationTitle("收藏")
            }
        }
    }
}
