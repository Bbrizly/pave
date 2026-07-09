import Foundation

public struct RunError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum StepError: Error, CustomStringConvertible {
    case busy
    case timedOut(stepIndex: Int)
    case failed(stepIndex: Int, reason: String)

    public var description: String {
        switch self {
        case .busy: return "a macro is already running"
        case .timedOut(let i): return "hit the 30s cap before step \(i + 1)"
        case .failed(let i, let reason): return "step \(i + 1) failed: \(reason)"
        }
    }
}

public protocol StepRunner {
    func run(_ step: Step) throws
}

/// One serial executor. A running macro blocks new fires.
/// Hard cap checked between steps; shell steps carry their own timeout.
public final class Executor {
    private let queue = DispatchQueue(label: "com.bbrizly.pave.executor")
    private let lock = NSLock()
    private var running = false
    public var maxRuntime: TimeInterval = 30

    public init() {}

    /// Returns false (and completes with .busy) if a macro is already running.
    @discardableResult
    public func run(_ macro: Macro, with runner: StepRunner,
                    completion: @escaping (Result<Void, StepError>) -> Void) -> Bool {
        lock.lock()
        if running {
            lock.unlock()
            completion(.failure(.busy))
            return false
        }
        running = true
        lock.unlock()

        queue.async { [self] in
            defer {
                lock.lock()
                running = false
                lock.unlock()
            }
            let start = Date()
            for (i, step) in macro.steps.enumerated() {
                if Date().timeIntervalSince(start) > maxRuntime {
                    completion(.failure(.timedOut(stepIndex: i)))
                    return
                }
                if case .unknown(let t) = step {
                    completion(.failure(.failed(stepIndex: i, reason: "unknown step type '\(t)'")))
                    return
                }
                do {
                    try runner.run(step)
                } catch {
                    completion(.failure(.failed(stepIndex: i, reason: String(describing: error))))
                    return
                }
            }
            completion(.success(()))
        }
        return true
    }
}
