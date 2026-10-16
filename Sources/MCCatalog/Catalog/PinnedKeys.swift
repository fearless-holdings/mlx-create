import Foundation

/// Public keys the app trusts to sign catalogs (KTD2, `docs/lld/models.md` §4). Only public keys live here;
/// private keys stay outside the repository. `isDevelopment` keys must not be pinned in a build that sets a catalog URL,
/// which `mc-catalog verify --release` enforces.
public enum PinnedKeys {
    /// Development key `ed25519-f48c3ab410482fa4`. Remove before any release that sets a catalog URL.
    public static let keys: [PinnedCatalogKey] = [
        PinnedCatalogKey(publicKey: Data(base64Encoded: "dgvHCe+xyEkhVl7zdsfR/hRbjeGpo+VioPONgciQfQg=")!, isDevelopment: true)
    ]
}
