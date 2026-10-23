import SwiftUI
import SwiftData

// 题目详情：从题库列表点进来，完整题干 + 全部选项 + 正确答案高亮 + 解析 + 收藏开关
struct QuestionDetailView: View {
    @Environment(\.modelContext) private var context
    let question: Question

    private let letters = ["A", "B", "C", "D", "E"]

    private var typeText: String {
        question.isMulti ? "多选题" : (question.options.count == 2 ? "判断题" : "单选题")
    }

    private func isCorrectOption(_ i: Int) -> Bool {
        question.isMulti ? question.answerIndices.contains(i) : question.answerIndex == i
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text(typeText)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                    Text(question.deckName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(question.stem)
                    .font(.title3)
                    .bold()
                    .textSelection(.enabled)
                VStack(spacing: 10) {
                    ForEach(question.options.indices, id: \.self) { i in
                        HStack(alignment: .top) {
                            Text(letters[i]).bold()
                            Text(question.options[i])
                            Spacer()
                            if isCorrectOption(i) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            isCorrectOption(i) ? Color.green.opacity(0.18)
                                               : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                    }
                }
                Text("正确答案：\(question.correctAnswerText)")
                    .bold()
                    .foregroundStyle(.green)
                if !question.explanation.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("解析").bold()
                        Text(question.explanation)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("刷过 \(question.totalAttempts) 次，对 \(question.correctAttempts) 次，错 \(question.wrongCount) 次")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    question.isFavorite.toggle()
                    try? context.save()
                } label: {
                    Label(question.isFavorite ? "取消收藏" : "收藏这道题",
                          systemImage: question.isFavorite ? "star.fill" : "star")
                }
                .tint(.orange)
            }
            .padding()
        }
        .navigationTitle("题目详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    question.isFavorite.toggle()
                    try? context.save()
                } label: {
                    Image(systemName: question.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(question.isFavorite ? .yellow : .primary)
                }
            }
        }
    }
}
