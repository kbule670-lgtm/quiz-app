import SwiftUI

// 刷题页：一题一屏，选完立刻判分，答错标红+给解析
struct QuizView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let session: QuizSession

    private let letters = ["A", "B", "C", "D"]

    var body: some View {
        NavigationStack {
            Group {
                if session.isFinished {
                    finishedView
                } else if let q = session.current {
                    questionView(q)
                }
            }
            .navigationTitle("刷题中")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("退出") {
                        try? context.save()
                        dismiss()
                    }
                }
            }
        }
    }

    private var finishedView: some View {
        VStack(spacing: 16) {
            Text("刷完啦").font(.title).bold()
            Text("答对 \(session.correctCount) / \(session.total)")
                .font(.title2)
            let wrong = session.total - session.correctCount
            if wrong > 0 {
                Text("\(wrong) 道进了错题本")
                    .foregroundStyle(.secondary)
            }
            Button("再来一轮") { session.restart() }
                .primaryGlassButton()
            Button("退出") {
                try? context.save()
                dismiss()
            }
        }
        .padding()
    }

    private func questionView(_ q: Question) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("第 \(session.cursor + 1) / \(session.total) 题")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(q.stem)
                    .font(.title3)
                    .bold()
                ForEach(q.options.indices, id: \.self) { i in
                    Button { session.choose(i) } label: {
                        HStack {
                            Text(letters[i]).bold()
                            Text(q.options[i])
                            Spacer()
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(OptionSurface(color: optionColor(i, q: q),
                                                answered: session.answered))
                    }
                    .disabled(session.answered)
                    .foregroundStyle(.primary)
                }
                if session.answered {
                    if session.selectedIndex == q.answerIndex {
                        Text("答对了 ✓").foregroundStyle(.green).bold()
                    } else {
                        Text("答错了，正确答案是 \(letters[q.answerIndex])")
                            .foregroundStyle(.red).bold()
                    }
                    if !q.explanation.isEmpty {
                        Text("解析：" + q.explanation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Button(session.cursor + 1 < session.total ? "下一题" : "看成绩") {
                        session.next()
                    }
                    .primaryGlassButton()
                }
            }
            .padding()
        }
    }

    private func optionColor(_ i: Int, q: Question) -> Color {
        guard session.answered else { return Color(.secondarySystemBackground) }
        if i == q.answerIndex { return .green.opacity(0.25) }
        if i == session.selectedIndex { return .red.opacity(0.25) }
        return Color(.secondarySystemBackground)
    }
}
