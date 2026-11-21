import Foundation

/// Pulls one top-level string field out of a JSON reply as it streams (plan KTD21): `feed` returns the newly available,
/// unescaped characters of the field's value so the UI can show the agent's sentence while the rest of the object is
/// still arriving.
///
/// A scalar-level state machine: it tracks object/array depth, strings and escapes; only a key at depth 1 equal to
/// `field` whose value is a string is emitted. Text before the first `{` (a markdown fence, a preamble) is ignored,
/// a same-named key inside a nested object or array is ignored, and nothing is emitted after the value's closing
/// quote. JSON escapes (`\" \\ \/ \b \f \n \r \t` and `\uXXXX`, including a surrogate pair) decode as they complete,
/// buffered across deltas.
public struct PlanTextStreamer: Sendable {
    /// Everything `feed` has returned so far.
    public private(set) var text = ""

    public init(field: String = "text") {
        self.field = field
    }

    /// Feeds the next delta and returns the newly available characters of the field's value ("" when none arrived).
    public mutating func feed(_ delta: String) -> String {
        var emitted = ""
        for scalar in delta.unicodeScalars {
            if done { break }
            if inString {
                if escape != .none {
                    continueEscape(scalar, into: &emitted)
                } else {
                    handleStringScalar(scalar, into: &emitted)
                }
                continue
            }
            if depth == 0 {
                if scalar == "{" {
                    depth = 1
                    expectingKey = true
                }
                continue
            }
            switch scalar {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 { done = true }
            case "[":
                depth += 1
            case "]":
                depth -= 1
            case "\"":
                inString = true
                if depth == 1 && expectingKey {
                    readingKey = true
                    keyBuffer = ""
                    expectingKey = false
                } else if depth == 1 && awaitingValue && lastKey == field {
                    emitting = true
                    awaitingValue = false
                } else if depth == 1 {
                    awaitingValue = false
                }
            case ":":
                if depth == 1 && !expectingKey { awaitingValue = true }
            case ",":
                if depth == 1 {
                    expectingKey = true
                    awaitingValue = false
                }
            default:
                if depth == 1 && awaitingValue && !Self.isWhitespace(scalar) { awaitingValue = false }
            }
        }
        text += emitted
        return emitted
    }

    private let field: String
    private var depth = 0
    private var inString = false
    private var escape: Escape = .none
    private var readingKey = false
    private var keyBuffer = ""
    private var lastKey = ""
    /// The last depth-1 scalar was the object's `{` or a `,`: the next string is a key.
    private var expectingKey = false
    /// A `:` just closed a depth-1 key; the next non-whitespace scalar decides whether the value is the string.
    private var awaitingValue = false
    private var emitting = false
    private var done = false

    private enum Escape: Sendable, Equatable {
        case none
        /// The previous scalar was `\`.
        case start
        /// `\u` plus the hex digits received so far.
        case unicode(String)
        /// A high surrogate completed; awaiting `\uXXXX` for the low half.
        case surrogate(UInt16)
        /// The `\` after a high surrogate was seen; awaiting `u`.
        case surrogateSlash(UInt16)
        /// The second `\u` plus its hex digits so far.
        case surrogateUnicode(UInt16, String)
    }

    /// One scalar inside a string, outside any escape: a backslash opens an escape, a quote closes the string, and
    /// anything else is a character of the key or the emitted value.
    private mutating func handleStringScalar(_ scalar: Unicode.Scalar, into emitted: inout String) {
        switch scalar {
        case "\\":
            escape = .start
        case "\"":
            inString = false
            if emitting {
                emitting = false
                done = true
            }
            if readingKey {
                readingKey = false
                lastKey = keyBuffer
            }
        default:
            route(String(scalar), into: &emitted)
        }
    }

    /// The next scalar of a pending escape. Emits nothing until the escape is whole, so a `\uXXXX` split across
    /// deltas arrives as one character. A malformed escape emits U+FFFD and the scalar falls through as content.
    private mutating func continueEscape(_ scalar: Unicode.Scalar, into emitted: inout String) {
        switch escape {
        case .none:
            handleStringScalar(scalar, into: &emitted)
        case .start:
            escape = .none
            switch scalar {
            case "n": route("\n", into: &emitted)
            case "t": route("\t", into: &emitted)
            case "r": route("\r", into: &emitted)
            case "b": route("\u{8}", into: &emitted)
            case "f": route("\u{c}", into: &emitted)
            case "\"", "/", "\\": route(String(scalar), into: &emitted)
            case "u": escape = .unicode("")
            default: route(String(scalar), into: &emitted)
            }
        case .unicode(let digits):
            guard Self.isHexDigit(scalar) else {
                route("\u{FFFD}", into: &emitted)
                escape = .none
                handleStringScalar(scalar, into: &emitted)
                return
            }
            var digits = digits
            digits.append(Character(scalar))
            guard digits.count == 4 else {
                escape = .unicode(digits)
                return
            }
            let value = UInt16(digits, radix: 16)!
            if (0xD800...0xDBFF).contains(value) {
                escape = .surrogate(value)
            } else {
                escape = .none
                route(Self.scalarString(for: value), into: &emitted)
            }
        case .surrogate(let high):
            escape = .none
            if scalar == "\\" {
                escape = .surrogateSlash(high)
            } else {
                route("\u{FFFD}", into: &emitted)
                handleStringScalar(scalar, into: &emitted)
            }
        case .surrogateSlash(let high):
            escape = .none
            if scalar == "u" {
                escape = .surrogateUnicode(high, "")
            } else {
                route("\u{FFFD}", into: &emitted)
                route(String(scalar), into: &emitted)
            }
        case .surrogateUnicode(let high, let digits):
            guard Self.isHexDigit(scalar) else {
                route("\u{FFFD}", into: &emitted)
                escape = .none
                handleStringScalar(scalar, into: &emitted)
                return
            }
            var digits = digits
            digits.append(Character(scalar))
            guard digits.count == 4 else {
                escape = .surrogateUnicode(high, digits)
                return
            }
            escape = .none
            let low = UInt16(digits, radix: 16)!
            guard (0xDC00...0xDFFF).contains(low) else {
                route("\u{FFFD}", into: &emitted)
                route(Self.scalarString(for: low), into: &emitted)
                return
            }
            let combined = UInt32(high) << 10 + UInt32(low) - 0x35FDC00
            route(String(Unicode.Scalar(combined)!), into: &emitted)
        }
    }

    /// Appends decoded text to the emitted output (inside the target value) or the key buffer (inside a depth-1
    /// key); characters of any other string are dropped.
    private mutating func route(_ string: String, into emitted: inout String) {
        if emitting { emitted += string }
        if readingKey { keyBuffer += string }
    }

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
    }

    private static func isHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        (scalar >= "0" && scalar <= "9") || (scalar >= "a" && scalar <= "f") || (scalar >= "A" && scalar <= "F")
    }

    /// The scalar for a `\uXXXX` value that is not part of a surrogate pair; a lone low surrogate becomes U+FFFD.
    private static func scalarString(for value: UInt16) -> String {
        Unicode.Scalar(value).map(String.init) ?? "\u{FFFD}"
    }
}
