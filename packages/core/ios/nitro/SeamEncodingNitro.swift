// SeamEncodingNitro.swift — local copy of the seam policy for the Nitro module.
// The public BridgeKit module has the testable original in engine/SeamEncoding.swift.

import Foundation

enum SeamEncoding {
    static let failedCode = "SEAM_ENCODE_FAILED"

    static func failureTerminal(context: String, error: Error) -> [String: Any?] {
        [
            "ok": false,
            "code": failedCode,
            "message": "Failed to encode \(context) for the JS seam: \(error)"
        ]
    }

    static func reportFailure(context: String, error: Error) {
        print("[bridgekit] seam encoding failed for \(context): \(error)")
    }
}

final class SeamTerminalGuard {
    private let lock = NSLock()
    private var terminated = false

    var isTerminated: Bool {
        lock.lock(); defer { lock.unlock() }
        return terminated
    }

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if terminated { return false }
        terminated = true
        return true
    }
}
