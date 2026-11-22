import Foundation

/// DEBUG-only counter of main-thread I/O violations, surfaced in tests and the debug HUD.
public enum FSCoreDiagnostics {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var violations: [String] = []

    public static func recordMainThreadIOViolation(message: String, location: String) {
        lock.lock()
        defer { lock.unlock() }
        violations.append("\(message) @ \(location)")
    }

    public static var recordedViolations: [String] {
        lock.lock()
        defer { lock.unlock() }
        return violations
    }

    public static func resetViolations() {
        lock.lock()
        defer { lock.unlock() }
        violations.removeAll()
    }
}
