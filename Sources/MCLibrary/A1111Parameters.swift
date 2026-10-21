import Foundation

/// Parses the Automatic1111 `parameters` text: prompt, optional `Negative prompt:`, then one settings line.
/// Reads the format ``MetadataCodec/a1111Parameters(_:)`` writes, and the one other tools write.
public enum A1111Parameters {
 private static let settingsKeys = ["Steps:", "CFG scale:", "Seed:", "Size:", "Sampler:", "Model:"]
 private static let negativePrefix = "Negative prompt:"
 private static let loraTagOpen = "<lora:"
 private static let maxTagLength = 256

 /// Returns nil when the text has neither a settings line nor a `Negative prompt:` line.
 public static func parse(_ text: String) -> ImageGenerationData? {
  let lines = text.components(separatedBy: "\n").map {
   $0.hasSuffix("\r") ? String($0.dropLast()) : $0
  }
  let settingsIndex = lines.lastIndex { isSettingsLine(leadingTrimmed($0)) }
  let end = settingsIndex ?? lines.count
  let negativeIndex = lines[..<end].firstIndex { leadingTrimmed($0).hasPrefix(negativePrefix) }
  guard settingsIndex != nil || negativeIndex != nil else { return nil }

  var negative: String?
  if let negativeIndex {
   let firstLine = String(leadingTrimmed(lines[negativeIndex]).dropFirst(negativePrefix.count))
   let body = [firstLine] + lines[(negativeIndex + 1)..<end]
   let joined = trimmed(body.joined(separator: "\n"))
   negative = joined.isEmpty ? nil : joined
  }

  let rawPrompt = trimmed(lines[..<(negativeIndex ?? end)].joined(separator: "\n"))
  let stripped = stripLoRATags(from: rawPrompt)
  let prompt = stripped.tags.isEmpty ? rawPrompt : tidy(stripped.text)

  var fields: [String: String] = [:]
  if let settingsIndex {
   for field in splitFields(leadingTrimmed(lines[settingsIndex])) {
    guard let colon = field.firstIndex(of: ":") else { continue }
    let key = field[..<colon].trimmingCharacters(in: .whitespaces)
    let value = String(field[field.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    if fields[key] == nil {
     fields[key] = value
    }
   }
  }

  let size = fields["Size"].flatMap(parseSize)
  let modelName = fields["Model"].flatMap { $0.isEmpty ? nil : $0 }

  // A hash entry takes the weight of the first tag with the same name; tags with no entry follow, unmatched.
  var seen = Set<String>()
  var loras: [ImageGenerationData.LoRAReference] = []
  for entry in loraHashEntries(fields["Lora hashes"]) {
   guard seen.insert(entry.name.lowercased()).inserted else { continue }
   let weight =
    stripped.tags.first { $0.name.lowercased() == entry.name.lowercased() }?.weight ?? 1.0
   loras.append(
    ImageGenerationData.LoRAReference(name: entry.name, hash: entry.hash, weight: weight))
  }
  for tag in stripped.tags {
   guard seen.insert(tag.name.lowercased()).inserted else { continue }
   loras.append(ImageGenerationData.LoRAReference(name: tag.name, hash: "", weight: tag.weight))
  }

  return ImageGenerationData(
   source: .a1111,
   prompt: prompt,
   negativePrompt: negative,
   steps: fields["Steps"].flatMap { Int($0) },
   guidance: fields["CFG scale"].flatMap { Double($0) }.flatMap { $0.isFinite ? $0 : nil },
   seed: fields["Seed"].flatMap { Int64($0) },
   width: size?.width,
   height: size?.height,
   modelName: modelName,
   loras: loras
  )
 }

 private static func trimmed(_ text: String) -> String {
  text.trimmingCharacters(in: .whitespacesAndNewlines)
 }

 private static func leadingTrimmed(_ line: String) -> Substring {
  line.drop(while: \.isWhitespace)
 }

 private static func isSettingsLine(_ line: Substring) -> Bool {
  settingsKeys.contains { line.hasPrefix($0) }
 }

 /// Splits on commas outside double quotes and outside `[]`/`{}` nesting.
 private static func splitFields(_ line: Substring) -> [String] {
  var fields: [String] = []
  var current = ""
  var inQuotes = false
  var depth = 0
  for character in line {
   if character == "\"" {
    inQuotes.toggle()
   } else if !inQuotes {
    switch character {
    case "[", "{":
     depth += 1
    case "]", "}":
     depth = max(0, depth - 1)
    case "," where depth == 0:
     fields.append(current)
     current = ""
     continue
    default:
     break
    }
   }
   current.append(character)
  }
  fields.append(current)
  return fields
 }

 /// `WxH`, both sides positive integers.
 private static func parseSize(_ value: String) -> (width: Int, height: Int)? {
  let parts = value.split(separator: "x", omittingEmptySubsequences: false)
  guard parts.count == 2,
   let width = Int(parts[0].trimmingCharacters(in: .whitespaces)),
   let height = Int(parts[1].trimmingCharacters(in: .whitespaces)),
   width > 0, height > 0
  else { return nil }
  return (width, height)
 }

 /// `"name: hash, name: hash"`; each entry splits at its last `: `. Entries without a name or hash are skipped.
 private static func loraHashEntries(_ field: String?) -> [(name: String, hash: String)] {
  guard var list = field else { return [] }
  if list.count >= 2, list.hasPrefix("\""), list.hasSuffix("\"") {
   list = String(list.dropFirst().dropLast())
  }
  var entries: [(name: String, hash: String)] = []
  for part in list.components(separatedBy: ",") {
   let entry = part.trimmingCharacters(in: .whitespaces)
   guard let separator = entry.range(of: ": ", options: .backwards) else { continue }
   let name = entry[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
   let hash = entry[separator.upperBound...].trimmingCharacters(in: .whitespaces)
   guard !name.isEmpty, !hash.isEmpty else { continue }
   entries.append((name, hash))
  }
  return entries
 }

 private struct Tag {
  let name: String
  let weight: Double
 }

 /// Removes every well-formed `<lora:NAME>`, `<lora:NAME:WEIGHT>` or `<lora:NAME:WEIGHT:extra>` tag.
 private static func stripLoRATags(from prompt: String) -> (text: String, tags: [Tag]) {
  var kept = ""
  var tags: [Tag] = []
  var rest = prompt[...]
  while let open = rest.range(of: loraTagOpen) {
   kept += rest[..<open.lowerBound]
   let afterOpen = rest[open.upperBound...]
   // A tag is short: look for its `>` only in a bounded window that ends at a line break, so an unclosed tag never rescans the rest.
   let window = afterOpen.prefix(maxTagLength)
   if let close = window.firstIndex(where: { $0 == ">" || $0.isNewline }), window[close] == ">",
    let tag = parseTag(afterOpen[..<close])
   {
    tags.append(tag)
    rest = afterOpen[afterOpen.index(after: close)...]
   } else {
    kept += loraTagOpen
    rest = afterOpen
   }
  }
  kept += rest
  return (kept, tags)
 }

 /// `body` is the text between `<lora:` and `>`.
 private static func parseTag(_ body: Substring) -> Tag? {
  let parts = body.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
  guard let first = parts.first else { return nil }
  let name = first.trimmingCharacters(in: .whitespaces)
  guard !name.isEmpty else { return nil }
  guard parts.count > 1 else { return Tag(name: name, weight: 1.0) }
  guard let weight = decimal(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
  return Tag(name: name, weight: weight)
 }

 private static func decimal(_ text: String) -> Double? {
  guard text.allSatisfy({ "-.0123456789".contains($0) }),
   let value = Double(text), value.isFinite
  else { return nil }
  return value
 }

 /// Collapses the double spaces a removed tag leaves, then trims whitespace and surrounding commas.
 private static func tidy(_ text: String) -> String {
  var collapsed = text
  while collapsed.contains("  ") {
   collapsed = collapsed.replacingOccurrences(of: "  ", with: " ")
  }
  return collapsed.trimmingCharacters(
   in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
 }
}
