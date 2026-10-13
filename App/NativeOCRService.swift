import Foundation

enum NativeOCRError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

/// Serializes native calls. The bridge's atomic cancel flag is the only operation
/// permitted concurrently with inference. No Swift task runs the C loop on MainActor.
final class NativeOCRService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SuryaStudy.inference", qos: .userInitiated)
    private let lock = NSLock()
    private var engine: OpaquePointer?
    private var cancellationRequested = false
    private var running = false
    private let modelURL: URL
    private let projectorURL: URL

    init(modelURL: URL, projectorURL: URL) {
        self.modelURL = modelURL
        self.projectorURL = projectorURL
    }

    deinit {
        if let engine { surya_engine_destroy(engine) }
    }

    func recognize(imageURL: URL, progress: @escaping @Sendable (Int) -> Void) async throws -> String {
        try begin()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        try checkCancellation()
                        let handle = try loadEngine()
                        try checkCancellation()
                        let state = TokenProgress(callback: progress)
                        let context = Unmanaged.passUnretained(state).toOpaque()
                        var nativeError: UnsafeMutablePointer<CChar>?
                        let result = surya_engine_recognize(handle, imageURL.path, 12288, { _, _, context in
                            guard let context else { return }
                            Unmanaged<TokenProgress>.fromOpaque(context).takeUnretainedValue().advance()
                        }, context, &nativeError)
                        // Keeps callback context alive through the synchronous native call.
                        withExtendedLifetime(state) {}
                        defer {
                            if let result { surya_string_free(result) }
                            if let nativeError { surya_string_free(nativeError) }
                        }
                        try checkCancellation()
                        guard let result else {
                            throw NativeOCRError.message(nativeError.map { String(cString: $0) } ?? "모델 추론에 실패했습니다.")
                        }
                        let html = String(cString: result)
                        finish()
                        continuation.resume(returning: html)
                    } catch {
                        finish()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        if let engine { surya_engine_cancel(engine) }
        lock.unlock()
    }

    private func begin() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { throw NativeOCRError.message("이미 처리 중인 페이지가 있습니다.") }
        cancellationRequested = false
        if let engine { surya_engine_reset_cancel(engine) }
        running = true
    }

    private func finish() {
        lock.lock()
        running = false
        lock.unlock()
    }

    private func checkCancellation() throws {
        lock.lock()
        let cancelled = cancellationRequested
        lock.unlock()
        if cancelled { throw CancellationError() }
    }

    private func loadEngine() throws -> OpaquePointer {
        // All loading/destruction is on this serial queue; cancel reads under lock.
        lock.lock()
        let existing = engine
        lock.unlock()
        if let existing { return existing }

        var nativeError: UnsafeMutablePointer<CChar>?
        let created = surya_engine_create(modelURL.path, projectorURL.path, 16384, true, &nativeError)
        defer { if let nativeError { surya_string_free(nativeError) } }
        guard let created else {
            throw NativeOCRError.message(nativeError.map { String(cString: $0) } ?? "모델을 불러올 수 없습니다.")
        }
        lock.lock()
        engine = created
        if cancellationRequested { surya_engine_cancel(created) }
        lock.unlock()
        return created
    }
}

private final class TokenProgress {
    private var count = 0
    private let callback: @Sendable (Int) -> Void

    init(callback: @escaping @Sendable (Int) -> Void) { self.callback = callback }

    func advance() {
        count += 1
        if count == 1 || count.isMultiple(of: 32) { callback(count) }
    }
}
