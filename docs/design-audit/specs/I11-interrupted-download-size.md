# I11 · Interrupted download: report the bytes really downloaded

| | |
|---|---|
| Tag | INTERACTION |
| Severity (Nielsen 0–4) | 2, minor: after cancelling at 438 MB, the row says "Interrupted at 2,03 GB of 4,62 GB", nearly five times the real figure, so the user expects a much shorter resume than they get |
| Frequency | Every cancelled or interrupted model download |
| Heuristics | H1 Visibility of system status (accuracy) |
| User task | (a) first launch to first kept image, including the download |
| Strategy metric | Time to first kept image (download included) |
| HLD decisions | No D* change. Resume sidecars and the staging manifest (D27) are untouched |
| Size | S |
| Depends on | none |

## Evidence

- Screenshot: `screens/02c-model-download-interrupted_small_light.png`: "Interrupted at 2,03 GB of 4,62 GB. Resume to continue."
- At the same moment, `du -sh` of the throwaway home showed **427 MB**, and the only large file was `Models/.partial/…/text_encoder/0.safetensors.partial` with an apparent size of 2,029,547,256 bytes. The parallel range download writes at offsets, so the partial file is sparse: its logical size is the final size and its allocated size is what has arrived.
- Code: `Sources/MCModels/InstallStaging.swift`, `private static func directorySize(_:)`, sums `.fileSizeKey` (logical size). `StagedInstall.bytesOnDisk` feeds `ModelBrowserRow.State.interrupted(bytesOnDisk:bytesTotal:)` and `InstallRow`.
- HIG, Progress indicators: "Be as accurate as possible when reporting advancement."

## Target behavior

`bytesOnDisk` counts allocated bytes (`.totalFileAllocatedSizeKey`), capped at each file's logical size so that block rounding never reports more than the file holds. The row then reads, for example, "Interrupted at 438 MB of 4.62 GB. Resume to continue."

## Edit steps

1. `Sources/MCModels/InstallStaging.swift`: change `private static func directorySize(_ directory: URL) -> Int64` to `static func directorySize(_ directory: URL) -> Int64` (internal, for the test), and its body to:

   ```swift
   let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]
   guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else {
       return 0
   }
   var total: Int64 = 0
   for case let url as URL in enumerator {
       guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
       // A partial written by ranged parts is sparse: its logical size is the final size, its allocated size is what
       // arrived (I11). Allocation is rounded up to whole blocks, so it never counts past the logical size.
       let logical = Int64(values.fileSize ?? 0)
       let allocated = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
       total += min(logical, allocated)
   }
   return total
   ```

2. Add a test to `Tests/MCModelsTests/ModelInstallerTests.swift`, or a new `Tests/MCModelsTests/InstallStagingSizeTests.swift` (Swift Testing, `@testable import MCModels`):

   ```swift
   @Test func aSparsePartialCountsOnlyTheBytesWritten() throws {
       let dir = FileManager.default.temporaryDirectory.appending(path: "staging-\(UUID().uuidString)", directoryHint: .isDirectory)
       try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
       defer { try? FileManager.default.removeItem(at: dir) }
       let file = dir.appending(path: "weights.safetensors.partial")
       FileManager.default.createFile(atPath: file.path, contents: nil)
       let handle = try FileHandle(forWritingTo: file)
       try handle.truncate(atOffset: 64 * 1024 * 1024)       // 64 MiB logical, nothing allocated
       try handle.seek(toOffset: 0)
       try handle.write(contentsOf: Data(repeating: 1, count: 1024 * 1024))  // 1 MiB written
       try handle.close()
       let size = InstallStaging.directorySize(dir)
       #expect(size >= 1024 * 1024)
       #expect(size < 8 * 1024 * 1024)
   }
   ```

3. Format the touched files.

## Do not touch

- `ModelDownloader`, the `.parts` sidecars and resume logic.
- `InstallRow` copy (the "Interrupted at … of …" sentence stays).

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0, including the new test (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter MCModelsTests`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.

Optional live check (it downloads real weights, so **ask the user first**): in an empty home, start FLUX.2 klein 4B, cancel after about 30 s, and compare the row's "Interrupted at X" with `du -sk` of `Models/.partial`. They agree within 5 %.
