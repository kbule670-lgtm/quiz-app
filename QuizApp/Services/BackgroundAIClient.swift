import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// 云端 AI 后台传输（8.ipa）：把云端请求放到后台 URLSession 里跑，
// App 切到后台、锁屏、甚至被系统挂起后，网络传输部分由系统继续跑完。
//
// 边界（必须如实说明，不得向用户承诺「锁屏后一定能跑完整本导入」）：
// 1) 后台会话只保证网络传输由系统继续；App 被唤醒处理结果时后台时间有限，
//    所以结果必须按段即时落库（复用 7.ipa 的分段入库），多次唤醒可续。
// 2) Vision OCR 与本地处理在后台仍会被暂停，回来后靠逐页存档续跑。
// 3) 本 App 是纯 SwiftUI 入口、没有 AppDelegate 的后台会话回调钩子：
//    App 被完全终止后，未完成请求的最终结果会在下次启动重建同标识会话时
//    重新挂接；导入重跑时检查点会跳过已落库段，不重复、不重复扣费。
// 目标口径统一为：前台正常跑、切走或锁屏时尽量继续、被挂起或终止后
// 重开能从已保存页面与批次恢复。
enum BackgroundTransportError: Error {
    case sessionUnavailable
}

final class BackgroundAIClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    static let shared = BackgroundAIClient()

    private struct Pending {
        var data: Data
        var response: URLResponse?
        var continuation: CheckedContinuation<(Data, Int), Error>
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.kabule.quizapp.cloudai")
#if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
        config.sessionSendsLaunchEvents = true
#endif
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var pending: [Int: Pending] = [:]
    private let lock = NSLock()

    // 一次 POST：返回原始响应体与响应。网络错误/HTTP 错误由调用方按原口径处理
    // （重试与统计都在 ConcurrentChunkRunner 里，不在这里改语义）。
    func post(url: URL, body: Data, headers: [String: String]) async throws
        -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, Int), Error>) in
            let task = session.dataTask(with: request)
            lock.lock()
            pending[task.taskIdentifier] = Pending(data: Data(), response: nil,
                                                   continuation: cont)
            lock.unlock()
            task.resume()
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        lock.lock()
        if var p = pending[dataTask.taskIdentifier] {
            p.data.append(data)
            pending[dataTask.taskIdentifier] = p
        }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        if var p = pending[dataTask.taskIdentifier] {
            p.response = response
            pending[dataTask.taskIdentifier] = p
        }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        lock.lock()
        guard let p = pending.removeValue(forKey: task.taskIdentifier) else {
            lock.unlock()
            return
        }
        lock.unlock()
        if let error = error {
            p.continuation.resume(throwing: error)
        } else if let response = p.response {
            // 状态码在这里抽出来：调用方只拿 Int，不用再碰 HTTPURLResponse
            //（Linux 上它在 FoundationNetworking 里，iOS 上在 Foundation 里，
            //  conditional import 让两边都能编过）
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            p.continuation.resume(returning: (p.data, status))
        } else {
            p.continuation.resume(throwing: URLError(.unknown))
        }
    }
}
