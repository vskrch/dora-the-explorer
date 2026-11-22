import Testing
@testable import AppCore

@Test func packageLoads() {
    #expect(SortDescriptorValue(key: .name, ascending: true).ascending)
    #expect(ViewKind.allCases.count == 8)
}
