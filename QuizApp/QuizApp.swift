// App 入口：只做一件事——搭好 SwiftData 容器，装 Question 这张表
import SwiftUI
import SwiftData

@main
struct QuizApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: Question.self)
    }
}
