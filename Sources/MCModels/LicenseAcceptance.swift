import Foundation

/// The user's acceptance of one model's license at one license version (D20, KTD10). An install needs one that names
/// the model it installs; the coordinator in `MCApp` checks the license id and version against the current catalog.
public struct LicenseAcceptance: Sendable, Equatable {
    public let modelID: String
    public let licenseID: String
    public let licenseVersion: String
    public let acceptedAt: Date

    public init(modelID: String, licenseID: String, licenseVersion: String, acceptedAt: Date) {
        self.modelID = modelID
        self.licenseID = licenseID
        self.licenseVersion = licenseVersion
        self.acceptedAt = acceptedAt
    }
}
