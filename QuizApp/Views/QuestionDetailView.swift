import SwiftUI

// 临时空壳（仅用于定位编译错误）
struct QuestionDetailView: View {
    let question: Question

    var body: some View {
        Text(question.stem)
            .navigationTitle("题目详情")
    }
}
