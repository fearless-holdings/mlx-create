import Foundation
import Testing

@testable import MCModels

/// Keychain tests use a per-run service name, so the app's saved key is never read or changed.
@Suite struct CivitaiKeychainTests {
    private func testKeychain() -> CivitaiKeychain {
        CivitaiKeychain(service: "app.mlx-create.civitai.tests.\(UUID().uuidString)")
    }

    @Test func savedKeyRoundTripsOverwritesAndDeletes() throws {
        let keychain = testKeychain()
        defer { try? keychain.delete() }

        #expect(try keychain.read() == nil)
        try keychain.write("civitai-test-key-first")
        #expect(try keychain.read() == "civitai-test-key-first")
        try keychain.write("civitai-test-key-second")
        #expect(try keychain.read() == "civitai-test-key-second")
        try keychain.delete()
        #expect(try keychain.read() == nil)
    }

    @Test func deletingWhenNothingIsSavedSucceeds() throws {
        let keychain = testKeychain()
        defer { try? keychain.delete() }

        try keychain.delete()

        #expect(try keychain.read() == nil)
    }

    @Test func separateServiceNamesKeepSeparateKeys() throws {
        let first = testKeychain()
        let second = testKeychain()
        defer {
            try? first.delete()
            try? second.delete()
        }

        try first.write("civitai-test-key-a")

        #expect(try second.read() == nil)
    }
}
