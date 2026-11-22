import Testing
@testable import ShellIntegration

@Test func packageLoads() {
    #expect(ShellIntegrationEntryPoints.urlScheme == "fenestra")
}
