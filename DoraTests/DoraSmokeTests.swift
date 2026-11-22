import Foundation
import Testing
@testable import Dora

@Suite("App smoke")
struct DoraSmokeTests {
    @Test func bundleIdentifierIsStable() {
        #expect(Bundle.main.bundleIdentifier?.hasSuffix("dora") != false)
    }
}
