import SwiftUI

// 刷题页：一题一屏。单选/判断点一个就判分；多选先勾选、点提交才判分。
// 右上角星星是收藏开关，点亮收进收藏夹，再点取消。
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
                if let q = session.current {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            q.isFavorite.toggle()
                            try? context.save()
                        } label: {
                            Image(systemName: q.isFavorite ? "star.fill" : "star")
                                .foregroundStyle(q.isFavorite ? .yellow : .primary)
                        }
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
                HStack {
                    Text("第 \(session.cursor + 1) / \(session.total) 题")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(q.isMulti ? "多选题" : (q.options.count == 2 ? "判断题" : "单选题"))
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                    if q.isMulti && !session.answered {
                        Text("可多选，选好点提交")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(q.stem)
                    .font(.title3)
                    .bold()
                ForEach(q.options.indices, id: \.self) { i in
                    Button {
                        if q.isMulti { session.toggle(i) } else { session.choose(i) }
                    } label: {
                        HStack {
                            Text(letters[i]).bold()
                            Text(q.options[i])
                            Spacer()
                            if q.isMulti && session.selectedSet.contains(i) {
                                Image(systemName: "checkmark.circle.fill")
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(OptionSurface(color: optionColor(i, q: q),
                                                answered: session.answered))
                    }
                    .disabled(session.answered)
                    .foregroundStyle(.primary)
                }
                if q.isMulti && !session.answered {
                    Button("提交答案") { session.submitMulti() }
                        .primaryGlassButton()
                        .disabled(session.selectedSet.isEmpty)
                }
                if session.answered {
                    if wasCorrect(q) {
                        Text("答对了 ✓").foregroundStyle(.green).bold()
                    } else {
                        Text("答错了，正确答案是 \(q.correctAnswerText)")
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

    private func wasCorrect(_ q: Question) -> Bool {
        if q.isMulti { return session.selectedSet == Set(q.answerIndices) }
        return session.selectedIndex == q.answerIndex
    }

    private func optionColor(_ i: Int, q: Question) -> Color {
        if q.isMulti {
            if session.answered {
                if q.answerIndices.contains(i) { return .green.opacity(0.25) }
                if session.selectedSet.contains(i) { return .red.opacity(0.25) }
                return Color(.secondarySystemBackground)
            }
            return session.selectedSet.contains(i)
                ? .blue.opacity(0.25)
                : Color(.secondarySystemBackground)
        }
        guard session.answered else { return Color(.secondarySystemBackground) }
        if i == q.answerIndex { return .green.opacity(0.25) }
        if i == session.selectedIndex { return .red.opacity(0.25) }
        return Color(.secondarySystemBackground)
    }
}
