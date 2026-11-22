import Foundation
import os

/// Loggers, one per feature area, all on the app's subsystem.
public enum DoraLog {
    public static let subsystem = "com.dorasoft.dora"

    public static func make(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    public static let fsCore = make("fscore")
    public static let fileOps = make("fileops")
    public static let thumbnails = make("thumbnails")
    public static let search = make("search")
    public static let archives = make("archives")
    public static let shell = make("shell")
    public static let ui = make("ui")
    public static let perf = make("perf")
}
