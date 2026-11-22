import Testing
@testable import Archives

@Test func packageLoads() {
    #expect(ArchiveFormat.allCases.contains(.zip))
}
