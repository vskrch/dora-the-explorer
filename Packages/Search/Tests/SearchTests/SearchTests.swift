import Foundation
import Testing
@testable import Search

@Test func packageLoads() {
    let scope = SearchScope(root: URL(fileURLWithPath: "/"), descendants: true)
    #expect(scope.descendants)
}
