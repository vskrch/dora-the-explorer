import Foundation

/// Guards the project rule: filesystem I/O must never run on the main thread.
///
/// Called at the top of every enumeration / stat / metadata entry point in FSCore.
/// In release builds this compiles to nothing.
public func assertNotMainThreadForIO(
    _ function: StaticString = #function,
    file: StaticString = #fileID,
    line: UInt = #line
) {
    #if DEBUG
    if Thread.isMainThread {
        let message = "Filesystem I/O on the main thread in \(function) — move it to an FSCore actor"
        let detail = "\(file):\(line)"
        FSCoreDiagnostics.recordMainThreadIOViolation(message: message, location: detail)
        assertionFailure("\(message) (\(detail))")
    }
    #endif
}
