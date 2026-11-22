import OSLog

extension OSSignposter {
    /// `OSLog` for a subsystem/category pair, for `OSSignpostID(log:)`.
    public static func loggerForCategory(_ subsystem: String, _ category: String) -> OSLog {
        OSLog(subsystem: subsystem, category: category)
    }
}

/// Signpost helpers for the project's performance budgets.
public enum Signposter {
    public static let logger = FenestraLog.perf
    public static let performance = OSSignposter(logger: logger)

    /// Runs `work` in a signpost interval named `name`.
    public static func measure<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let state = performance.beginInterval(name)
        defer { performance.endInterval(name, state) }
        return try work()
    }

    /// Async variant.
    public static func measure<T>(_ name: StaticString, _ work: @Sendable () async throws -> T) async rethrows -> T {
        let state = performance.beginInterval(name)
        defer { performance.endInterval(name, state) }
        return try await work()
    }
}
