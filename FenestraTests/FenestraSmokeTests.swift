import Foundation
import Testing
@testable import Fenestra

@Suite("App smoke")
struct FenestraSmokeTests {
    @Test func bundleIdentifierIsStable() {
        #expect(Bundle.main.bundleIdentifier?.hasSuffix("fenestra") != false)
    }
}
