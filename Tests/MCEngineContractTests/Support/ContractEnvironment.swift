import Foundation

/// Inputs of the contract suite (`docs/lld/engine-contract.md` §3). Every suite is gated on `enabled`, so a bare
/// `swift test` never starts a real-model run: `MLXC_ENGINE_BIN` alone is already set for the engine tests.
enum ContractEnvironment {
    private static let values = ProcessInfo.processInfo.environment

    /// Both variables are required: the engine under test and the directory of real models.
    static let enabled = values["MLXC_ENGINE_BIN"] != nil && values["MLXC_CONTRACT_MODEL_DIR"] != nil

    /// Extracted `mlx-serve` of the version under test.
    static var engineBinary: URL { URL(fileURLWithPath: values["MLXC_ENGINE_BIN"] ?? "/nonexistent") }

    /// Directory of model folders, the engine's `--model-dir` layout.
    static var modelDirectory: URL { URL(fileURLWithPath: values["MLXC_CONTRACT_MODEL_DIR"] ?? "/nonexistent", isDirectory: true) }

    /// `<family id>/*.safetensors`, the layout the app writes under `Models/LoRAs`. Nil when unset.
    static var loraDirectory: URL? {
        values["MLXC_CONTRACT_LORA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Where the ledger writes the result of a complete run. Nil when unset: the run then records nothing.
    static var resultURL: URL? {
        values["MLXC_CONTRACT_RESULT"].map { URL(fileURLWithPath: $0) }
    }
}
