import Foundation
import Network

/// Whether macOS lets this program touch the local network at all.
///
/// Since macOS 15 every app needs an explicit grant (Privacy & Security ▸ Local Network).
/// Without it Bonjour returns nothing and every connection to a LAN address fails — silently,
/// with an empty list and no error anywhere a person can see. The system log says
/// "Local network prohibited"; the Network framework says the same as an unsatisfied path
/// reason, and that is what this asks.
///
/// It matters most in development: the grant is tied to the app's signature, so every rebuild
/// looks like a different app and the permission quietly falls away.
enum LocalNetworkPermission {
    enum State: Equatable {
        case granted
        case denied
        /// No answer in time — the network may simply be down. Never shown as a refusal.
        case unknown
    }

    /// Ask the system, with a deadline. Answers `.denied` only when the path says exactly that.
    static func check(host: String, port: UInt16 = 445,
                      timeout: TimeInterval = 1.2) async -> State {
        await withCheckedContinuation { continuation in
            var answered = false
            let queue = DispatchQueue(label: "com.fcxl.localnet.permission")
            let endpoint = NWEndpoint.Host(host)
            guard let port = NWEndpoint.Port(rawValue: port) else {
                continuation.resume(returning: .unknown); return
            }
            let connection = NWConnection(host: endpoint, port: port, using: .tcp)
            func finish(_ state: State) {
                queue.async {
                    guard !answered else { return }
                    answered = true
                    connection.cancel()
                    continuation.resume(returning: state)
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.granted)
                case .waiting(let error), .failed(let error):
                    finish(reading(error))
                default:
                    break
                }
            }
            connection.pathUpdateHandler = { path in
                if path.unsatisfiedReason == .localNetworkDenied { finish(.denied) }
                else if path.status == .satisfied { finish(.granted) }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(.unknown) }
        }
    }

    /// A refusal is a refusal only when the system names it. "Host is down" is not.
    /// "Connection refused" is the opposite of a refusal: the packet reached the router and
    /// came back — the filter is not standing in the way. Silence alone stays unknown.
    static func reading(_ error: NWError) -> State {
        if case .posix(let code) = error {
            if code == .EPERM { return .denied }
            if code == .ECONNREFUSED || code == .ECONNRESET { return .granted }
        }
        return "\(error)".localizedCaseInsensitiveContains("local network") ? .denied : .unknown
    }

    /// What to tell a person whose scan found nobody. A named refusal is a refusal; silence
    /// after a full scan is suspicious enough to say so — macOS keeps a program off the local
    /// network without a word when its prompt never came, and the person sees the same empty
    /// list as on an empty network. A reachable gateway means the network really is empty.
    enum Advice: Equatable { case denied, unsure }
    static func adviceAfterEmptyScan(_ state: State) -> Advice? {
        switch state {
        case .denied:  return .denied
        case .unknown: return .unsure
        case .granted: return nil
        }
    }

    /// Стоит ли сказать это вслух.
    ///
    /// Названный отказ — всегда: список при запрете НЕ пуст. Имена приносит Bonjour, а их
    /// отдаёт системный демон из своего кэша, ему запрет не помеха; прямые соединения самой
    /// программы при этом гасятся все до одного, и половины сети — компьютеров, которые
    /// находятся только опросом порта, — человек не видит. Раньше проверка ждала пустого
    /// списка и потому молчала ровно в том случае, ради которого писалась.
    /// Молчание же — повод для разговора, только когда не нашлось вообще никого.
    static func shouldWarn(_ advice: Advice, afterScan: Bool, listIsEmpty: Bool) -> Bool {
        switch advice {
        case .denied: return true
        case .unsure: return afterScan && listIsEmpty
        }
    }

    /// Where a person goes to switch it on.
    static let settingsURL = URL(string:
        "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!
}
