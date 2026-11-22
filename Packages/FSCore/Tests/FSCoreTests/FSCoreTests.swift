import Foundation
import Testing
@testable import FSCore

@Test func fileItemIdentityAndDerivedFields() {
    let url = URL(fileURLWithPath: "/tmp/report.final.pdf")
    let item = FileItem(id: "1:2", url: url, name: url.lastPathComponent, isDirectory: false, size: 42)
    #expect(item.nameWithoutExtension == "report.final")
    #expect(item.fileExtension == "pdf")
    #expect(item.id == "1:2")
    #expect(item.size == 42)
}

@Test func mainThreadIOAssertionIsRecorded() {
    FSCoreDiagnostics.resetViolations()
    // Called from a test thread (not main) — must not record a violation.
    assertNotMainThreadForIO()
    #expect(FSCoreDiagnostics.recordedViolations.isEmpty)
}
