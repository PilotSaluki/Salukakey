// ══════════════════════════════════════════════════════════════════
//  main.swift — SalukaKey
//  Automatic keyboard layout switcher for macOS
//
//  Build:
//    swiftc -O -o SalukaKey Sources/main.swift \
//           -framework AppKit -framework Carbon
//
//  Or use the provided build.sh to create a proper .app bundle.
//
//  Permissions required:
//    • Accessibility (System Settings → Privacy & Security → Accessibility)
//    • Input Monitoring (System Settings → Privacy & Security → Input Monitoring)
// ══════════════════════════════════════════════════════════════════

import AppKit
import Carbon
import CoreGraphics
import UniformTypeIdentifiers

// TISCreateInputSourceList is not auto-bridged into Swift;
// we import it via @_silgen_name (it was renamed from TISCopyInputSourceList
// in the dyld shared cache on modern macOS).
@_silgen_name("TISCreateInputSourceList")
func TISCreateInputSourceList(
    _ properties: CFDictionary,
    _ includeAllInstalled: Bool
) -> Unmanaged<CFArray>

// Global reference to the app instance, needed because the CGEventTap
// C callback cannot capture Swift context. (Belt-and-suspenders
// alongside the refcon pointer.)
var gApp: SalukaKeyApp!

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Constants
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Time window for detecting a double-shift gesture (seconds).
private let kDoubleShiftInterval: TimeInterval = 0.30

/// Public release page opened by "Check GitHub for Updates...".
private let kGitHubReleasesURL =
    URL(string: "https://github.com/PilotSaluki/Salukakey/releases/latest")!

/// Minimum letters for the spell-check fast path.
///
/// Two-letter prefixes are hopelessly ambiguous in Russian (almost
/// every pair is the start of some word), so we wait for a third
/// letter before trusting the switch. Two-letter words like "ns"
/// → "ты" are left to double-Shift.
private let kAutoSwitchMinChars = 3

/// Minimum letters for the frequency/vowel fallback. Four letters
/// give the frequency tables enough signal; three-letter fallback
/// switches were the main source of false positives.
private let kAutoSwitchFreqMinChars = 4

/// Minimum letters for a whole-word correction at a boundary
/// (space/punctuation). Two-letter words are worth checking once the
/// word is complete: "ns" typed in English is not a word, "ты" is.
private let kBoundaryMinChars = 2

/// Virtual keycodes (from Carbon/Events.h).
private let kVK_Delete:     UInt16 = 0x33
private let kVK_Shift:      UInt16 = 0x38
private let kVK_RightShift: UInt16 = 0x3C
private let kVK_ANSI_A:     UInt16 = 0x00
private let kVK_ANSI_C:     UInt16 = 0x08
private let kVK_ANSI_V:     UInt16 = 0x09
private let kVK_Return:     UInt16 = 0x24
private let kVK_Tab:        UInt16 = 0x30
private let kVK_Space:      UInt16 = 0x31
private let kVK_Escape:     UInt16 = 0x35

/// Navigation / editing keys that invalidate the "last typed token"
/// history: the caret is no longer guaranteed to be right after our text.
private let kVK_LeftArrow:     UInt16 = 0x7B
private let kVK_RightArrow:    UInt16 = 0x7C
private let kVK_DownArrow:     UInt16 = 0x7D
private let kVK_UpArrow:       UInt16 = 0x7E
private let kVK_Home:          UInt16 = 0x73
private let kVK_End:           UInt16 = 0x77
private let kVK_PageUp:        UInt16 = 0x74
private let kVK_PageDown:      UInt16 = 0x79
private let kVK_ForwardDelete: UInt16 = 0x75
private let kVK_KeypadEnter:   UInt16 = 0x4C


/// Magic value written into CGEventSource.userData so that
/// the event-tap callback can recognise (and skip) our own
/// simulated keystrokes.
private let kSimulatedEventMarker: Int64 = 0x43_41_52_41   // "CARA"

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - KeyStroke
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// A single keystroke recorded in the word buffer.
struct KeyStroke {
    let keyCode: UInt16
    let character: Character
    let shifted: Bool
    /// Case of the character that was actually produced. This is not
    /// the same as `shifted`: Caps Lock also changes the case, and
    /// the target layout must reproduce the same case.
    let uppercase: Bool

    init(keyCode: UInt16,
         character: Character,
         shifted: Bool,
         uppercase: Bool? = nil) {
        self.keyCode = keyCode
        self.character = character
        self.shifted = shifted
        self.uppercase = uppercase ??
            (character.isLetter ? character.isUppercase : shifted)
    }
}

/// A character the user typed, stored so that a double-Shift can
/// convert the last token even when nothing is selected.
struct TypedChar {
    let character: Character
    let sourceID: String?
    let keyCode: UInt16
    let shifted: Bool
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Unicode helpers
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

extension Character {
    /// True for Basic Latin letters (A-Z, a-z).
    var isLatinLetter: Bool {
        guard let s = unicodeScalars.first else { return false }
        return (0x0041...0x005A).contains(s.value) ||   // A–Z
               (0x0061...0x007A).contains(s.value)      // a–z
    }

    /// True for Cyrillic letters (U+0400 – U+04FF).
    var isCyrillicLetter: Bool {
        guard let s = unicodeScalars.first else { return false }
        return (0x0400...0x04FF).contains(s.value)
    }

    /// True for English vowels (case-insensitive).
    var isEnglishVowel: Bool {
        "aeiouAEIOU".contains(self)
    }

    /// True for Russian vowels (case-insensitive).
    var isRussianVowel: Bool {
        "аеёиоуыэюяАЕЁИОУЫЭЮЯ".contains(self)
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Script enum
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// The dominant script of a keyboard layout, inferred from its
/// character map.
enum LayoutScript {
    case latin
    case cyrillic
    case other
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - InputSourceManager
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Wraps the Text Input Source (TIS*) C API with safe Swift helpers.
/// Builds per-layout character maps via `UCKeyTranslate` so that
/// we can transliterate text between layouts by physical key position.
final class InputSourceManager {

    /// keycode → Character for both unshifted and shifted states.
    struct CharacterMap {
        let unshifted: [UInt16: Character]    // keycode → char  (no shift)
        let shifted:   [UInt16: Character]    // keycode → char  (shift held)
        let reverseUnshifted: [Character: UInt16]
        let reverseShifted:   [Character: UInt16]
        let script: LayoutScript
    }

    /// Cached maps keyed by InputSourceID.
    private(set) var maps: [String: CharacterMap] = [:]

    init() { rebuildMaps() }

    // ── Querying sources ─────────────────────────────────────

    /// All selectable, enabled keyboard input sources.
    func enabledSources() -> [TISInputSource] {
        let conditions: [String: Any] = [
            kTISPropertyInputSourceCategory as String:
                kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsEnabled as String: true,
            kTISPropertyInputSourceIsSelectCapable as String: true
        ]

        let cfArray = TISCreateInputSourceList(
            conditions as CFDictionary, false
        ).takeRetainedValue()
        guard let list = cfArray as? [TISInputSource] else { return [] }
        return list
    }

    /// Currently active keyboard input source.
    func currentSource() -> TISInputSource? {
        TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    }

    /// InputSourceID string (e.g. "com.apple.keylayout.US").
    func sourceID(_ src: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(src, kTISPropertyInputSourceID)
        else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// Localised human-readable name (e.g. "U.S.", "Russian").
    func sourceName(_ src: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(src, kTISPropertyLocalizedName)
        else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// The InputSourceID of the currently active source, or nil.
    func currentSourceID() -> String? {
        currentSource().flatMap { sourceID($0) }
    }

    // ── Selecting sources ────────────────────────────────────

    func select(_ src: TISInputSource) -> OSStatus {
        TISSelectInputSource(src)
    }

    /// Cycle to the next enabled keyboard source and return it.
    @discardableResult
    func cycleToNext() -> TISInputSource? {
        let sources = enabledSources()
        guard sources.count > 1,
              let curID = currentSourceID() else { return nil }

        let idx = sources.firstIndex(where: { sourceID($0) == curID }) ?? 0
        let next = sources[(idx + 1) % sources.count]
        _ = select(next)
        return next
    }

    /// Activate a specific input source by its ID.
    /// Returns `false` if the source is missing or the system refused
    /// the selection, so callers can fall back to Unicode injection.
    @discardableResult
    func selectByID(_ id: String) -> Bool {
        guard let src = enabledSources().first(where: { sourceID($0) == id })
        else { return false }
        return select(src) == noErr
    }

    // ── Character maps ───────────────────────────────────────

    /// Rebuild character maps for every enabled keyboard source.
    /// Called on every input-source notification, but the maps only
    /// change when the *set* of enabled sources changes — rebuilding
    /// them on every layout switch would add pointless latency to
    /// the event tap.
    func rebuildMaps() {
        let sources = enabledSources()
        let ids = sources.compactMap { sourceID($0) }
        if !maps.isEmpty && Set(ids) == Set(maps.keys) { return }

        maps.removeAll()
        for src in sources {
            guard let id = sourceID(src),
                  let map = buildMap(for: src) else { continue }
            maps[id] = map
        }
        if maps.isEmpty {
            NSLog("[SalukaKey] Warning: could not build character maps "
                + "for any enabled input source.")
        }
    }

    /// Translate a single Character from one layout to another by
    /// matching its physical key position (keycode + shift state).
    func translate(_ ch: Character,
                   from srcID: String,
                   to dstID: String) -> Character? {
        guard let srcMap = maps[srcID],
              let dstMap = maps[dstID] else { return nil }

        // Try unshifted first, then shifted.
        if let kc = srcMap.reverseUnshifted[ch] {
            return dstMap.unshifted[kc]
        }
        if let kc = srcMap.reverseShifted[ch] {
            return dstMap.shifted[kc]
        }
        return nil
    }

    /// Translate an entire string between two layouts.
    func translateString(_ text: String,
                         from srcID: String,
                         to dstID: String) -> String {
        String(text.map { translate($0, from: srcID, to: dstID) ?? $0 })
    }

    /// Enabled sources that have a usable character map, in system order.
    func orderedSources() -> [(id: String, script: LayoutScript)] {
        enabledSources().compactMap { src in
            guard let id = sourceID(src), let map = maps[id] else {
                return nil
            }
            return (id, map.script)
        }
    }

    /// Pick the best (source, destination) layout pair for `text`.
    ///
    /// • Text with Latin/Cyrillic letters is converted from the layout
    ///   whose script matches the text to a layout with the opposite
    ///   script (EN ↔ RU).
    /// • Text with no Latin/Cyrillic letters (a lone symbol, digits)
    ///   is converted starting from the layout it was typed in, to the
    ///   next enabled layout.
    func conversionPair(
        for text: String,
        preferredSourceID: String?
    ) -> (src: String, dst: String)? {
        let sources = orderedSources()
        guard sources.count >= 2 else { return nil }

        var latin = 0
        var cyrillic = 0
        for ch in text where ch.isLetter {
            if ch.isLatinLetter       { latin += 1 }
            else if ch.isCyrillicLetter { cyrillic += 1 }
        }

        let srcID: String
        let dstID: String

        if latin > 0 || cyrillic > 0 {
            let wanted: LayoutScript = latin >= cyrillic ? .latin : .cyrillic
            let opposite: LayoutScript =
                wanted == .latin ? .cyrillic : .latin

            if let preferred = preferredSourceID,
               sources.first(where: { $0.id == preferred })?.script == wanted {
                srcID = preferred
            } else if let current = currentSourceID(),
                      sources.first(where: { $0.id == current })?.script
                        == wanted {
                srcID = current
            } else if let first = sources.first(where: { $0.script == wanted }) {
                srcID = first.id
            } else {
                return nil
            }

            let after = sourcesAfter(srcID, in: sources)
            if let destination = after.first(where: { $0.script == opposite })
                ?? after.first(where: { $0.id != srcID }) {
                dstID = destination.id
            } else {
                return nil
            }
        } else {
            guard let preferred = preferredSourceID ?? currentSourceID(),
                  sources.contains(where: { $0.id == preferred }),
                  let destination = sourcesAfter(preferred, in: sources).first
            else { return nil }
            srcID = preferred
            dstID = destination.id
        }

        return (srcID, dstID)
    }

    /// EN→RU pairs that live on punctuation keys. Hard-coded on
    /// purpose: a text string has lost the original keycode, and the
    /// reverse map cannot always tell whether "," was a real comma or
    /// the Russian "б" key.
    private static let enToRuPunctuation: [Character: Character] = [
        ",": "б", "<": "Б", ".": "ю", ">": "Ю",
        ";": "ж", ":": "Ж", "'": "э", "\"": "Э",
        "[": "х", "{": "Х", "]": "ъ", "}": "Ъ",
        "`": "ё", "~": "Ё", "/": ".", "?": ",",
    ]

    private static let ruToEnPunctuation: [Character: Character] = [
        "б": ",", "Б": "<", "ю": ".", "Ю": ">",
        "ж": ";", "Ж": ":", "э": "'", "Э": "\"",
        "х": "[", "Х": "{", "ъ": "]", "Ъ": "}",
        "ё": "`", "Ё": "~", ".": "/", ",": "?",
    ]

    /// Translate one character for a whole-token conversion.
    /// The explicit EN↔RU punctuation table takes precedence over the
    /// reverse keycode map for punctuation.
    func translateTokenCharacter(_ ch: Character,
                                 from srcID: String,
                                 to dstID: String) -> Character {
        guard let src = maps[srcID], let dst = maps[dstID] else {
            return translate(ch, from: srcID, to: dstID) ?? ch
        }
        if src.script == .latin && dst.script == .cyrillic,
           let hard = Self.enToRuPunctuation[ch] {
            return hard
        }
        if src.script == .cyrillic && dst.script == .latin,
           let hard = Self.ruToEnPunctuation[ch] {
            return hard
        }
        return translate(ch, from: srcID, to: dstID) ?? ch
    }

    /// Convert a whole token (word) between layouts.
    ///
    /// - If the token has no letters (a lone symbol), translate it
    ///   directly: `,` → `б`, `@` → `"`.
    /// - If the token's letters are valid in the source language,
    ///   keep its punctuation (real commas/quotes/brackets) and
    ///   translate only the letters.
    /// - If the token is not a valid source word (it was typed in the
    ///   wrong layout), translate letters and leading/internal
    ///   punctuation; trailing punctuation stays punctuation
    ///   (`ghbdtn,` → `привет,`).
    private func convertToken(_ token: String,
                              from srcID: String,
                              to dstID: String,
                              srcScript: LayoutScript) -> String {
        let chars = Array(token)
        let letterIndices = chars.indices.filter { chars[$0].isLetter }
        guard let lastLetter = letterIndices.last else {
            return String(chars.map {
                translateTokenCharacter($0, from: srcID, to: dstID)
            })
        }

        let letters = String(chars.filter { $0.isLetter })
        let sourceValid = LanguageHeuristics.isKnownWord(
            letters, script: srcScript)

        let first = chars.first
        let pairedQuote = chars.count >= 2
            && chars.first == chars.last
            && (first == "\"" || first == "'")

        var out = ""
        for (index, ch) in chars.enumerated() {
            if ch.isLetter {
                out.append(translateTokenCharacter(
                    ch, from: srcID, to: dstID))
                continue
            }
            if sourceValid {
                // Real punctuation in a valid source-language word.
                out.append(ch)
                continue
            }
            if index > lastLetter {
                // Trailing punctuation is punctuation, not a letter.
                out.append(ch)
                continue
            }
            if pairedQuote
                && (index == 0 || index == chars.count - 1) {
                out.append(ch)
                continue
            }
            out.append(translateTokenCharacter(
                ch, from: srcID, to: dstID))
        }
        return out
    }

    /// Convert arbitrary text between two layouts. Whitespace is
    /// preserved; each word is processed independently.
    func convertText(_ text: String,
                     from srcID: String,
                     to dstID: String) -> String {
        let srcScript = maps[srcID]?.script ?? .other
        var out = ""
        var token = ""

        func flush() {
            guard !token.isEmpty else { return }
            out += convertToken(token,
                                from: srcID,
                                to: dstID,
                                srcScript: srcScript)
            token = ""
        }

        for ch in text {
            if ch.isWhitespace {
                flush()
                out.append(ch)
            } else {
                token.append(ch)
            }
        }
        flush()
        return out
    }

    /// Sources after `id`, wrapping around to the beginning.
    private func sourcesAfter(
        _ id: String,
        in sources: [(id: String, script: LayoutScript)]
    ) -> [(id: String, script: LayoutScript)] {
        guard sources.count > 1,
              let index = sources.firstIndex(where: { $0.id == id })
        else { return sources }
        return (1..<sources.count).map {
            sources[(index + $0) % sources.count]
        }
    }

    /// Map a keycode (+ shift flag) to a character in the given layout.
    func character(forKeyCode kc: UInt16,
                   shifted: Bool,
                   inSourceID id: String) -> Character? {
        guard let m = maps[id] else { return nil }
        return shifted ? m.shifted[kc] : m.unshifted[kc]
    }

    // ── Private: UCKeyTranslate wrapper ──────────────────────

    private func buildMap(for src: TISInputSource) -> CharacterMap? {
        guard let ptr = TISGetInputSourceProperty(
            src, kTISPropertyUnicodeKeyLayoutData
        ) else { return nil }

        let data = Unmanaged<CFData>.fromOpaque(ptr)
            .takeUnretainedValue() as Data

        return data.withUnsafeBytes { raw -> CharacterMap? in
            guard let uchr = raw.baseAddress?
                    .assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return nil }

            let kbdType = UInt32(LMGetKbdType())
            var unshifted: [UInt16: Character] = [:]
            var shifted:   [UInt16: Character] = [:]

            for keyCode: UInt16 in 0..<128 {
                if let ch = ucKeyTranslate(uchr, keyCode,
                                           modifiers: 0,
                                           kbdType: kbdType) {
                    unshifted[keyCode] = ch
                }
                // Shift modifier: bit 1 in the 8-bit modifier field
                // (shiftKey = 0x0200; >> 8 = 2)
                if let ch = ucKeyTranslate(uchr, keyCode,
                                           modifiers: 2,
                                           kbdType: kbdType) {
                    shifted[keyCode] = ch
                }
            }

            // Build reverse maps (Character → keycode). Iterate in
            // keycode order and keep the first hit, so the main
            // keyboard wins over the numeric keypad (both can emit
            // "." or ",") and the mapping stays deterministic.
            var revUn: [Character: UInt16] = [:]
            for kc in unshifted.keys.sorted() {
                if let ch = unshifted[kc], revUn[ch] == nil {
                    revUn[ch] = kc
                }
            }
            var revSh: [Character: UInt16] = [:]
            for kc in shifted.keys.sorted() {
                if let ch = shifted[kc], revSh[ch] == nil {
                    revSh[ch] = kc
                }
            }

            // Determine the dominant script of this layout.
            var latinN = 0, cyrN = 0
            for ch in unshifted.values {
                if ch.isLatinLetter   { latinN += 1 }
                if ch.isCyrillicLetter { cyrN += 1 }
            }
            let script: LayoutScript
            if latinN > cyrN && latinN > 5       { script = .latin }
            else if cyrN > latinN && cyrN > 5    { script = .cyrillic }
            else                                 { script = .other }

            return CharacterMap(unshifted: unshifted,
                                shifted:   shifted,
                                reverseUnshifted: revUn,
                                reverseShifted:   revSh,
                                script: script)
        }
    }

    /// Low-level UCKeyTranslate call for a single keycode.
    private func ucKeyTranslate(
        _ layout: UnsafePointer<UCKeyboardLayout>,
        _ keyCode: UInt16,
        modifiers: UInt32,
        kbdType: UInt32
    ) -> Character? {
        var deadKey: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0

        let status = UCKeyTranslate(
            layout,
            keyCode,
            UInt16(kUCKeyActionDown),
            modifiers,
            kbdType,
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKey,
            4,
            &len,
            &chars
        )

        guard status == noErr, len > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: len)
        guard let ch = s.first,
              !ch.isNewline, ch != "\0" else { return nil }
        return ch
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - ShiftTracker
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Detects "clean" Shift presses (Shift pressed and released with
/// no other key in between) and distinguishes single-shift from
/// double-shift (two clean presses within `kDoubleShiftInterval`).
final class ShiftTracker {

    enum ShiftGesture {
        case none           // nothing interesting happened
        case singleShift    // one clean Shift tap
        case doubleShift    // two clean Shift taps in quick succession
    }

    private var shiftIsDown = false
    private var otherKeyWhileShift = false
    private var lastCleanShiftTime: Date?

    /// Call on every `.flagsChanged` event.
    /// `shiftPressed`: whether Shift is currently held (from event flags).
    func flagsChanged(shiftPressed: Bool) -> ShiftGesture {
        if shiftPressed && !shiftIsDown {
            // Shift just went down.
            shiftIsDown = true
            otherKeyWhileShift = false
            return .none
        }

        if !shiftPressed && shiftIsDown {
            // Shift just released.
            shiftIsDown = false

            if otherKeyWhileShift {
                // Shift was used for uppercase – not a gesture.
                lastCleanShiftTime = nil
                return .none
            }

            // Clean Shift tap.
            let now = Date()
            if let prev = lastCleanShiftTime,
               now.timeIntervalSince(prev) < kDoubleShiftInterval {
                lastCleanShiftTime = nil
                return .doubleShift
            }
            lastCleanShiftTime = now
            return .singleShift
        }

        return .none
    }

    /// Call on every `.keyDown` to mark that a key was typed while
    /// Shift was held — so it's not a "clean" Shift gesture.
    func keyDown() {
        if shiftIsDown {
            otherKeyWhileShift = true
        }
    }

    /// True when Shift is currently held down.
    var isShiftDown: Bool { shiftIsDown }

    /// Forget any pending gesture (app switch, master switch, etc.).
    func reset() {
        shiftIsDown = false
        otherKeyWhileShift = false
        lastCleanShiftTime = nil
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - KeySimulator
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Posts synthetic CGEvents marked with `kSimulatedEventMarker`
/// so our event-tap callback can recognise and ignore them.
enum KeySimulator {

    /// A dedicated CGEventSource whose `userData` is set to the
    /// marker value, so every event created from it carries the tag.
    private static let source: CGEventSource? = {
        let s = CGEventSource(stateID: .privateState)
        s?.userData = kSimulatedEventMarker
        return s
    }()

    /// Post a single key down + key up.
    static func tap(keyCode: UInt16, flags: CGEventFlags = []) {
        guard let src = source else { return }
        let down = CGEvent(keyboardEventSource: src,
                           virtualKey: keyCode, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src,
                           virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags   = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Simulate ⌘C (Copy).
    static func simulateCopy() {
        tap(keyCode: kVK_ANSI_C, flags: .maskCommand)
    }

    /// Simulate ⌘V (Paste).
    ///
    /// Only the key-down carries the Command flag. A key-up with
    /// Command still set can be treated as a second key equivalent by
    /// some AppKit text views, which pastes the text twice.
    static func simulatePaste() {
        guard let src = source else { return }
        let down = CGEvent(keyboardEventSource: src,
                           virtualKey: kVK_ANSI_V, keyDown: true)
        let up = CGEvent(keyboardEventSource: src,
                         virtualKey: kVK_ANSI_V, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = []
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Simulate N × Backspace to erase characters.
    static func simulateBackspace(count: Int) {
        for _ in 0..<count {
            tap(keyCode: kVK_Delete)
        }
    }

    /// Select the previous `count` characters (Shift+Left × count).
    static func selectPreviousCharacters(_ count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            tap(keyCode: kVK_LeftArrow, flags: .maskShift)
        }
    }

    /// Insert literal text through a synthetic keyboard event.
    ///
    /// The characters are carried in the event's Unicode payload, so
    /// they arrive exactly as given regardless of the active layout
    /// or of whether a TIS switch has propagated yet. This is how the
    /// auto-switch retypes the corrected prefix.
    static func typeUnicode(_ text: String) {
        guard let src = source, !text.isEmpty else { return }
        let units = Array(text.utf16)
        var index = 0
        // CGEvent's Unicode payload is limited to 20 UTF-16 units.
        while index < units.count {
            let end = min(index + 16, units.count)
            let chunk = Array(units[index..<end])
            index = end
            guard let down = CGEvent(keyboardEventSource: src,
                                     virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src,
                                   virtualKey: 0, keyDown: false)
            else { continue }
            down.keyboardSetUnicodeString(stringLength: chunk.count,
                                          unicodeString: chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count,
                                        unicodeString: chunk)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - PasteboardHelper
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Save / restore the general pasteboard around copy-convert-paste
/// operations so the user's clipboard is not clobbered.
enum PasteboardHelper {

    typealias Snapshot = [(NSPasteboard.PasteboardType, Data)]

    /// Standard "do not record this in clipboard history" markers.
    /// They are used by Clipboard History, Maccy, Paste, Raycast and
    /// other pasteboard managers.
    private static let markerTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
        NSPasteboard.PasteboardType(
            "de.petermaurer.TransientPasteboardType"),
    ]

    private static func markTransient(_ item: NSPasteboardItem) {
        for type in markerTypes {
            item.setString("1", forType: type)
        }
    }

    /// Take a snapshot of the current general pasteboard.
    static func save() -> Snapshot {
        let pb = NSPasteboard.general
        var snap = Snapshot()
        for item in pb.pasteboardItems ?? [] {
            for type in item.types {
                if let data = item.data(forType: type) {
                    snap.append((type, data))
                }
            }
        }
        return snap
    }

    /// Restore a previously saved snapshot. An empty snapshot means
    /// the clipboard was empty before us, so leave it empty. The
    /// restored item is marked transient so a clipboard manager does
    /// not add a duplicate entry for the restore itself.
    static func restore(_ snap: Snapshot) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !snap.isEmpty else { return }
        let item = NSPasteboardItem()
        for (type, data) in snap {
            item.setData(data, forType: type)
        }
        markTransient(item)
        pb.writeObjects([item])
    }

    /// Read the current pasteboard as a plain string.
    static func readString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    /// Write a plain string to the pasteboard, marked transient.
    static func writeString(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(s, forType: .string)
        markTransient(item)
        pb.writeObjects([item])
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - InputLogger
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Optional append-only diagnostics log.
///
/// **Disabled in release builds and not exposed in the UI.** The code
/// remains for local debugging, but normal users never get a log file.
final class InputLogger {

    static let shared = InputLogger()

    private let queue = DispatchQueue(
        label: "com.pilot.SalukaKey.input-log")
    private let fileManager = FileManager.default
    private let fileURL: URL
    private var handle: FileHandle?
    private var linesWritten = 0

    private(set) var isEnabled: Bool

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let dir = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SalukaKey",
                                    isDirectory: true)
        fileURL = dir.appendingPathComponent("input.log")

        // Release builds never create the directory or a log file.
        // `setEnabled(true)` is kept only for local debugging.
        isEnabled = false
    }

    var url: URL { fileURL }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled,
                                  forKey: "InputLoggingEnabled")
        if enabled {
            queue.sync {
                self.openHandleLocked()
                self.rotateIfNeededLocked()
            }
            log("logging enabled")
        } else {
            queue.sync {
                self.handle?.closeFile()
                self.handle = nil
            }
        }
    }

    func log(_ message: String) {
        guard isEnabled else { return }

        let stamp = Self.timestampFormatter.string(from: Date())
        let lines = message.split(separator: "\n",
                                  omittingEmptySubsequences: false)
        var payload = ""
        for line in lines {
            payload += "\(stamp) | \(line)\n"
        }
        let data = Data(payload.utf8)
        let lineCount = lines.count

        queue.async { [weak self] in
            guard let self = self, let handle = self.handle else {
                return
            }
            do {
                try handle.write(contentsOf: data)
                self.linesWritten += lineCount
                if self.linesWritten >= 2000 {
                    self.linesWritten = 0
                    self.rotateIfNeededLocked()
                }
            } catch {
                // Logging must never break typing.
            }
        }
    }

    func flush() {
        queue.sync {
            try? self.handle?.synchronize()
        }
    }

    func clear() {
        guard isEnabled else { return }
        queue.sync {
            self.handle?.closeFile()
            self.handle = nil
            try? self.fileManager.removeItem(at: self.fileURL)
            self.openHandleLocked()
        }
        log("log cleared")
    }

    // ── Private (queue-only) ────────────────────────────────

    private func openHandleLocked() {
        let dir = fileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(
            at: dir, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
            // The log contains typed text; keep it owner-only.
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        handle?.seekToEndOfFile()
    }

    private func rotateIfNeededLocked() {
        guard let attrs = try? fileManager.attributesOfItem(
                atPath: fileURL.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              size > 5_000_000 else { return }

        handle?.closeFile()
        handle = nil

        let old = fileURL.appendingPathExtension("1")
        try? fileManager.removeItem(at: old)
        try? fileManager.moveItem(at: fileURL, to: old)

        fileManager.createFile(atPath: fileURL.path, contents: nil)
        openHandleLocked()
    }
}

/// Scoring engine to decide whether a sequence of keycodes was
/// typed on the wrong keyboard layout.
///
/// **Strategy (v2 — letter-frequency scoring):**
///
/// Every letter in every language has a natural frequency.
/// When someone types "ghbdtn" on EN while meaning Russian "привет",
/// the English letter-frequency score is low (uncommon combo),
/// while the Russian score for "привет" is high (common letters).
///
/// For each enabled layout we:
///   1. Map the keycodes to characters via that layout's map.
///   2. Sum the per-letter frequency weights for that language.
///   3. If another layout's score beats the current one by a wide
///      margin (≥ 1.5×), switch.
///
/// Additionally, the old vowel-ratio check is kept as a fast-path
/// for the strongest signals (e.g. 0 % vowels on EN).
enum LanguageHeuristics {

    // ── Spell-check caches ───────────────────────────────────
    // The event tap calls the spell checker on every letter. The
    // same prefixes and words recur constantly, so cache the answers
    // (including negative ones) and keep the tap fast.
    private static var spellCache: [String: Bool] = [:]
    private static var completionCache: [String: Bool] = [:]
    private static let cacheLock = NSLock()
    private static let kCacheLimit = 4096

    // ── Letter-frequency tables ──────────────────────────────
    // Values are relative frequencies (per-thousand) from large
    // corpora, scaled so the most common letter ≈ 127.

    /// English letter frequencies (source: large corpus analysis).
    private static let enFreq: [Character: Double] = [
        "e": 127, "t": 91, "a": 82, "o": 75, "i": 70,
        "n": 67,  "s": 63, "h": 61, "r": 60, "d": 43,
        "l": 40,  "c": 28, "u": 28, "m": 24, "w": 24,
        "f": 22,  "g": 20, "y": 20, "p": 19, "b": 15,
        "v": 10,  "k":  8, "j":  2, "x":  2, "q":  1,
        "z":  1,
    ]

    /// Russian letter frequencies (source: large corpus analysis).
    private static let ruFreq: [Character: Double] = [
        "о": 110, "е": 85, "а": 80, "и": 74, "н": 67,
        "т": 63,  "с": 55, "р": 47, "в": 45, "л": 44,
        "к": 35,  "м": 32, "д": 30, "п": 28, "у": 26,
        "я": 20,  "ы": 19, "ь": 17, "г": 17, "з": 16,
        "б": 16,  "ч": 15, "й": 12, "х": 10, "ж":  9,
        "ш":  7,  "ю":  6, "ц":  5, "щ":  4, "э":  3,
        "ф":  3,  "ё":  3, "ъ":  1,
    ]

    /// Minimum ratio (otherScore / currentScore) to trigger a switch.
    /// 1.5 = the other layout must score at least 50 % higher.
    private static let kFreqRatioThreshold: Double = 1.5

    /// Result of one heuristic run, with a trace for the input log.
    struct Decision {
        let targetID: String?
        let trace: String
    }

    /// Load the system spelling dictionaries before the first word.
    static func warmUpSpellChecker() {
        DispatchQueue.main.async {
            _ = NSSpellChecker.shared.checkSpelling(
                of: "test", startingAt: 0, language: "en",
                wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            _ = NSSpellChecker.shared.checkSpelling(
                of: "тест", startingAt: 0, language: "ru",
                wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)

        }
    }

    // ── Public API ───────────────────────────────────────────

    /// Analyse the current word and return a decision plus a trace
    /// for the input log. `nil` means the word is too short.
    ///
    /// Primary signal: the system spell checker. If the typed text is
    /// not a word in the current language, but the same keycodes form
    /// a word in another enabled language, switch. This catches words
    /// like "ерштпы"→"things" that the old frequency tables missed.
    ///
    /// Fallback: the original letter-frequency / vowel heuristic for
    /// slang, names and words absent from the dictionaries.
    static func suggestedLayout(
        buffer: [KeyStroke],
        currentSourceID: String,
        mgr: InputSourceManager,
        atBoundary: Bool = false
    ) -> Decision? {
        let minimum = atBoundary ? kBoundaryMinChars : kAutoSwitchMinChars
        guard buffer.count >= minimum else { return nil }

        // ── What was actually typed ──────────────────────────
        let curLetters = buffer.compactMap { $0.character }
            .filter { $0.isLetter }
        guard curLetters.count >= minimum else { return nil }
        // The raw buffer keeps punctuation that is a letter on the
        // other layout ("," is "б"); the trace must show it.
        let rawWord = String(buffer.map { $0.character })

        // The buffer characters are resolved from the *claimed* TIS
        // source (see `resolvedCharacter`). They therefore describe
        // what the focused app actually inserted — unlike the CGEvent
        // Unicode string, which follows the global WindowServer
        // layout and is wrong whenever an app has a per-app input
        // source.
        let effectiveSourceID = currentSourceID

        guard let curMap = mgr.maps[effectiveSourceID] else { return nil }

        // Trust the actual typed characters over the map's script
        // when they disagree (per-app input-source switching can make
        // `currentSourceID` lag by one event).
        let curScript: LayoutScript
        if !curLetters.isEmpty,
           curLetters.allSatisfy({ $0.isCyrillicLetter }) {
            curScript = .cyrillic
        } else if !curLetters.isEmpty,
                  curLetters.allSatisfy({ $0.isLatinLetter }) {
            curScript = .latin
        } else {
            curScript = curMap.script
        }

        let curValid = isValidWord(curLetters, script: curScript)
        // A non-word prefix can still be the beginning of a real word
        // ("th" → "this", "gh" → "ghost"). Never hijack those.
        // At a word boundary the word is complete, so the prefix
        // guard no longer applies: "игн" is not a Russian word even
        // though it starts "игнорировать".
        let curHasCompletions = (atBoundary || curValid != false)
            ? false
            : hasCompletions(curLetters, script: curScript)
        let curFreqScore = frequencyScore(curLetters, script: curScript)
        let curVowelRatio = vowelRatio(curLetters, script: curScript)

        var bestID: String?
        var bestScore: Double = 0
        var trace: [String] = [
            "\(atBoundary ? "BOUNDARY" : "AUTO") word=\"\(rawWord)\" "
            + "layout=\(currentSourceID)"
            + " curValid=\(validText(curValid))"
            + " prefix=\(curHasCompletions ? "yes" : "no")"
        ]

        for (otherID, otherMap) in mgr.maps
            where otherID != effectiveSourceID
        {
            let otherChars: [Character] = buffer.compactMap { stroke in
                mgr.character(forKeyCode: stroke.keyCode,
                              shifted: stroke.shifted,
                              inSourceID: otherID)
            }
            guard otherChars.count == buffer.count else { continue }

            let otherLetters = otherChars.filter { $0.isLetter }
            guard otherLetters.count >= minimum else { continue }

            let nativeRatio = scriptMatchRatio(otherLetters,
                                               script: otherMap.script)
            guard nativeRatio >= 0.80 else { continue }

            let otherValid = isValidWord(otherLetters,
                                         script: otherMap.script)
            let otherHasCompletions = (otherValid == false)
                ? hasCompletions(otherLetters, script: otherMap.script)
                : false
            let otherFreqScore = frequencyScore(otherLetters,
                                                script: otherMap.script)
            let otherVowelRatio = vowelRatio(otherLetters,
                                             script: otherMap.script)
            let freqRatio = (curFreqScore > 0)
                ? otherFreqScore / curFreqScore
                : (otherFreqScore > 0 ? 999 : 0)

            var decision = "keep"
            var score = 0.0

            // ── 1. Spell-check fast path (primary) ─────────
            if curValid == false && otherValid == true {
                // Do not switch if the current text is a plausible
                // prefix of a word in its own language ("gh" in
                // "ghost", "gi" in "girl"). Otherwise a 2-letter
                // prefix would hijack a perfectly good word.
                if curHasCompletions {
                    decision = "keep(prefix)"
                } else {
                    decision = "SWITCH(spell)"
                    score = 1000.0 + freqRatio
                }
            } else if curValid == true {
                // Valid in the current language — even if it is also
                // valid in the other one — never touch it.
                decision = "keep(spell)"
            } else if !atBoundary
                        && curLetters.count >= kAutoSwitchFreqMinChars
                        && otherLetters.count >= kAutoSwitchFreqMinChars {
                // ── 2. Frequency / vowel fallback ───────────
                // Only for words outside the dictionaries. The
                // candidate must at least be a plausible prefix in
                // its own language; otherwise we would switch to a
                // random string that happens to use common letters.
                if curHasCompletions || !otherHasCompletions {
                    decision = "keep(prefix)"
                } else {
                    let vowelAdvantage = otherVowelRatio - curVowelRatio
                    let shouldSwitch =
                        (freqRatio >= kFreqRatioThreshold)
                        || (curVowelRatio < 0.12 && otherVowelRatio > 0.12)
                        || (vowelAdvantage > 0.20 && freqRatio > 1.15)

                    if shouldSwitch {
                        decision = "SWITCH(freq)"
                        score = freqRatio
                    }
                }
            }

            if score > bestScore {
                bestScore = score
                bestID = otherID
            }

            trace.append(String(
                format: "  -> %@ word=\"%@\" valid=%@ native=%.2f "
                    + "freq=%.2f vowels=%.2f/%.2f %@",
                otherID, String(otherChars), validText(otherValid),
                nativeRatio, freqRatio, curVowelRatio, otherVowelRatio,
                decision))
        }

        return Decision(targetID: bestID,
                        trace: trace.joined(separator: "\n"))
    }

    // ── Private helpers ──────────────────────────────────────

    /// Sum of letter frequencies for the given script.
    /// Higher score = the text looks more like natural language
    /// in that script.
    private static func frequencyScore(_ chars: [Character],
                                       script: LayoutScript) -> Double {
        let table: [Character: Double]
        switch script {
        case .latin:    table = enFreq
        case .cyrillic: table = ruFreq
        case .other:    return Double(chars.count) * 30  // neutral
        }
        return chars.reduce(0.0) { sum, ch in
            // Look up lowercase to match the frequency tables.
            let low = Character(String(ch).lowercased())
            return sum + (table[low] ?? 1.0)
        }
    }

    private static func vowelRatio(_ chars: [Character],
                                   script: LayoutScript) -> Double {
        guard !chars.isEmpty else { return 0 }
        let count: Int
        switch script {
        case .latin:
            count = chars.filter { $0.isEnglishVowel }.count
        case .cyrillic:
            count = chars.filter { $0.isRussianVowel }.count
        case .other:
            return 0.30
        }
        return Double(count) / Double(chars.count)
    }

    private static func scriptMatchRatio(_ chars: [Character],
                                         script: LayoutScript) -> Double {
        guard !chars.isEmpty else { return 0 }
        let count: Int
        switch script {
        case .latin:
            count = chars.filter { $0.isLatinLetter }.count
        case .cyrillic:
            count = chars.filter { $0.isCyrillicLetter }.count
        case .other:
            return 0.50
        }
        return Double(count) / Double(chars.count)
    }

    // ── Spell checking ──────────────────────────────────────

    /// Public helper for the token converter: does the source
    /// language dictionary know this word?
    static func isKnownWord(_ text: String, script: LayoutScript) -> Bool {
        let letters = Array(text.lowercased()).filter { $0.isLetter }
        return isValidWord(letters, script: script) == true
    }

    /// `true`/`false` when the system dictionary can judge the word,
    /// `nil` when checking is unavailable or the word is too short.
    private static func isValidWord(_ letters: [Character],
                                    script: LayoutScript) -> Bool? {
        guard letters.count >= 2 else { return nil }
        let word = String(letters).lowercased()
        switch script {
        case .latin:
            guard letters.allSatisfy({ $0.isLatinLetter }) else {
                return false
            }
            return spellCheck(word, language: "en")
        case .cyrillic:
            guard letters.allSatisfy({ $0.isCyrillicLetter }) else {
                return false
            }
            return spellCheck(word, language: "ru")
        case .other:
            return nil
        }
    }

    private static func spellCheck(_ word: String,
                                   language: String) -> Bool {
        let key = "\(language):\(word)"
        cacheLock.lock()
        if let cached = spellCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let range = NSSpellChecker.shared.checkSpelling(
            of: word,
            startingAt: 0,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil)
        let result = range.location == NSNotFound

        cacheLock.lock()
        if spellCache.count >= kCacheLimit {
            spellCache.removeAll(keepingCapacity: true)
        }
        spellCache[key] = result
        cacheLock.unlock()
        return result
    }

    /// True when the system dictionary can complete this prefix,
    /// i.e. it may be the beginning of a valid word ("gh" → "ghost").
    private static func hasCompletions(_ letters: [Character],
                                       script: LayoutScript) -> Bool {
        guard !letters.isEmpty else { return false }
        let word = String(letters).lowercased()
        let language: String
        switch script {
        case .latin:    language = "en"
        case .cyrillic: language = "ru"
        case .other:    return false
        }

        let key = "\(language):\(word)"
        cacheLock.lock()
        if let cached = completionCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let range = NSRange(location: 0, length: word.utf16.count)
        let completions = NSSpellChecker.shared.completions(
            forPartialWordRange: range,
            in: word,
            language: language,
            inSpellDocumentWithTag: 0)
        let result = !(completions?.isEmpty ?? true)

        cacheLock.lock()
        if completionCache.count >= kCacheLimit {
            completionCache.removeAll(keepingCapacity: true)
        }
        completionCache[key] = result
        cacheLock.unlock()
        return result
    }

    private static func validText(_ value: Bool?) -> String {
        switch value {
        case .some(true):  return "ok"
        case .some(false): return "bad"
        case .none:        return "?"
        }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - SwitchRecord (for undo)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Remembers the most recent automatic layout switch so that a
/// double-shift gesture can undo it.
struct SwitchRecord {
    let previousSourceID: String
    let newSourceID: String
    let timestamp: Date
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - SalukaKeyApp
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// The main controller: sets up the status-bar item, the event tap,
/// and orchestrates shift-tracking, auto-switching, and text
/// conversion.
final class SalukaKeyApp: NSObject, NSApplicationDelegate {

    // ── Sub-components ───────────────────────────────────────
    let inputManager = InputSourceManager()
    let shiftTracker = ShiftTracker()

    // ── Status bar ───────────────────────────────────────────
    private var statusItem: NSStatusItem!
    private var autoSwitchItem: NSMenuItem?
    private var allFunctionsItem: NSMenuItem?
    private var shiftSwitchItem: NSMenuItem?
    private var aboutWindowController: AboutWindowController?
    private var exclusionsWindowController: ExclusionsWindowController?

    // ── Exclusions ───────────────────────────────────────────
    private var frontmostBundleID: String?
    private var excludedBundleIDs: Set<String> = []

    // ── Event tap ────────────────────────────────────────────
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// PID for which `AXManualAccessibility`/`AXEnhancedUserInterface`
    /// has already been enabled.
    private var axEnabledPID: pid_t = -1

    // ── Word buffer for auto-switch ──────────────────────────
    private var wordBuffer: [KeyStroke] = []
    /// Prevent multiple auto-switches within one word.
    private var alreadySwitchedThisWord = false

    /// Punctuation typed immediately before the first letter of the
    /// current word. A key like "," is "б" on the Russian layout; if
    /// the whole word is later corrected, this prefix must be
    /// corrected too (",ольшой" → "большой").
    private var wordPrefixStrokes: [KeyStroke] = []

    // ── Last typed token (for double-Shift without a selection) ──
    /// Every character typed since the last "hard" boundary (click,
    /// arrow key, Return, app switch…). Double-Shift uses this to pick
    /// and convert the last word or symbol.
    private var typedRun: [TypedChar] = []

    /// True after a user gesture that normally creates a text
    /// selection: mouse drag, double-click, Shift+arrows, Cmd+A.
    /// Used as a safe signal to copy the selection in apps (Chrome,
    /// Electron) that do not expose `AXSelectedText`.
    private var selectionLikely = false

    // ── Undo / history ───────────────────────────────────────
    /// Last automatic (or single-shift) layout switch, for undo.
    var lastSwitch: SwitchRecord?

    // ── Simulation guard ─────────────────────────────────────
    /// True while we are posting simulated key events (to avoid
    /// infinite recursion in the tap callback).
    var isSimulating = false

    /// Automatic corrections can be switched off from the menu bar.
    /// Single Shift and double Shift keep working.
    var autoSwitchEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "AutoSwitchEnabled")
            == nil { return true }
        return UserDefaults.standard.bool(forKey: "AutoSwitchEnabled")
    }()

    /// Single-Shift layout switching can be switched off independently.
    var shiftSwitchEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "ShiftSwitchEnabled")
            == nil { return true }
        return UserDefaults.standard.bool(forKey: "ShiftSwitchEnabled")
    }()

    /// Master switch: disables auto-switch and double-Shift, while
    /// single Shift keeps cycling the layout.
    var allFunctionsDisabled: Bool = {
        if UserDefaults.standard.object(forKey: "AllFunctionsDisabled")
            == nil { return false }
        return UserDefaults.standard.bool(
            forKey: "AllFunctionsDisabled")
    }()

    // ══════════════════════════════════════════════════════════
    // MARK: NSApplicationDelegate
    // ══════════════════════════════════════════════════════════

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load the bundled icon explicitly so the Dock and About
        // window get it even when the executable is launched directly
        // from Terminal.
        if let iconURL = Bundle.main.url(forResource: "AppIcon",
                                         withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        // 1. Check / request Accessibility permission.
        requestAccessibility()
        enableAccessibilityForFrontmostApp()

        // Load the spelling dictionaries before the first word.
        LanguageHeuristics.warmUpSpellChecker()

        // Load persisted exclusions before the event tap starts.
        loadExcludedApps()
        frontmostBundleID =
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // 2. Build the status-bar item and the Dock app menu.
        setupStatusItem()
        setupMainMenu()

        // 3. Install the CGEventTap.
        if !installEventTap() {
            let alert = NSAlert()
            alert.messageText = "SalukaKey"
            alert.informativeText =
                "Could not create the keyboard event tap.\n\n"
                + "Please grant Accessibility and/or Input Monitoring "
                + "permissions in\n"
                + "System Settings → Privacy & Security,\n"
                + "then relaunch the app."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
        }

        // 4. Listen for system-wide input-source changes so we
        //    can update the menu-bar indicator.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceDidChange),
            name: NSNotification.Name(
                kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil
        )

        // 5. A different app means a different caret: forget the
        //    text behind the cursor.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        updateStatusTitle()

        let sourceCount = inputManager.enabledSources().count
        let mapCount = inputManager.maps.count
        NSLog("[SalukaKey] Ready. %d input sources, %d maps.",
              sourceCount, mapCount)
        InputLogger.shared.log(
            "READY sources=\(sourceCount) maps=\(mapCount) "
            + "log=\(InputLogger.shared.url.path)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        InputLogger.shared.log(
            "================ SalukaKey stopped ==============")
        InputLogger.shared.flush()
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        // The app lives in the menu bar even when About is closed.
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        // Clicking the Dock icon opens About when no window is visible.
        if !flag { showAbout() }
        return true
    }

    // ══════════════════════════════════════════════════════════
    // MARK: Status bar
    // ══════════════════════════════════════════════════════════

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        let autoItem = NSMenuItem(
            title: "Автоисправление текста",
            action: #selector(toggleAutoSwitch(_:)),
            keyEquivalent: "")
        autoItem.target = self
        autoSwitchItem = autoItem
        menu.addItem(autoItem)

        let allItem = NSMenuItem(
            title: "Отключение всех функций",
            action: #selector(toggleAllFunctions(_:)),
            keyEquivalent: "")
        allItem.target = self
        allFunctionsItem = allItem
        menu.addItem(allItem)

        let shiftItem = NSMenuItem(
            title: "Shift для смены раскладки",
            action: #selector(toggleShiftSwitch(_:)),
            keyEquivalent: "")
        shiftItem.target = self
        shiftSwitchItem = shiftItem
        menu.addItem(shiftItem)

        let exclusionsItem = NSMenuItem(
            title: "Программы исключения",
            action: #selector(showExclusions),
            keyEquivalent: "")
        exclusionsItem.target = self
        menu.addItem(exclusionsItem)

        let aboutItem = NSMenuItem(
            title: "About SalukaKey",
            action: #selector(showAbout),
            keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(
            title: "Quit SalukaKey",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateMenuStates()
    }

    /// Keep the six status-menu items in sync with persisted state.
    private func updateMenuStates() {
        autoSwitchItem?.state = autoSwitchEnabled ? .on : .off
        allFunctionsItem?.state = allFunctionsDisabled ? .on : .off
        shiftSwitchItem?.state = shiftSwitchEnabled ? .on : .off

        // Auto-switch is overridden by the master switch. Single
        // Shift remains independent and keeps working.
        autoSwitchItem?.isEnabled = !allFunctionsDisabled
        shiftSwitchItem?.isEnabled = true
        allFunctionsItem?.isEnabled = true
    }

    /// Standard application menu shown when the Dock icon is active.
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu(title: "SalukaKey")

        let about = NSMenuItem(title: "About SalukaKey",
                               action: #selector(showAbout),
                               keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)

        appMenu.addItem(.separator())

        let hide = NSMenuItem(title: "Hide SalukaKey",
                              action: #selector(NSApplication.hide(_:)),
                              keyEquivalent: "h")
        hide.target = NSApp
        appMenu.addItem(hide)

        let quit = NSMenuItem(title: "Quit SalukaKey",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)

        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    @objc private func showAbout() {
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController()
        }
        aboutWindowController?.showWindow(nil)
        aboutWindowController?.window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleAutoSwitch(_ sender: NSMenuItem) {
        guard !allFunctionsDisabled else { return }
        autoSwitchEnabled.toggle()
        UserDefaults.standard.set(autoSwitchEnabled,
                                  forKey: "AutoSwitchEnabled")
        updateMenuStates()
    }

    @objc private func toggleAllFunctions(_ sender: NSMenuItem) {
        allFunctionsDisabled.toggle()
        UserDefaults.standard.set(allFunctionsDisabled,
                                  forKey: "AllFunctionsDisabled")

        if allFunctionsDisabled {
            clearTypedRun()
            resetWordBuffer()
            selectionLikely = false
        }
        shiftTracker.reset()
        updateMenuStates()
    }

    @objc private func toggleShiftSwitch(_ sender: NSMenuItem) {
        shiftSwitchEnabled.toggle()
        UserDefaults.standard.set(shiftSwitchEnabled,
                                  forKey: "ShiftSwitchEnabled")
        updateMenuStates()
    }

    @objc private func showExclusions() {
        if exclusionsWindowController == nil {
            let controller = ExclusionsWindowController()
            controller.onChange = { [weak self] in
                self?.loadExcludedApps()
                self?.shiftTracker.reset()
            }
            exclusionsWindowController = controller
        }
        exclusionsWindowController?.refresh()
        exclusionsWindowController?.showWindow(nil)
        exclusionsWindowController?.window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Reload the persisted exclusion list.
    private func loadExcludedApps() {
        let ids = UserDefaults.standard.stringArray(
            forKey: "ExcludedBundleIDs") ?? []
        excludedBundleIDs = Set(ids)
    }

    private func isExcludedFrontmostApp() -> Bool {
        guard let id = frontmostBundleID else { return false }
        return excludedBundleIDs.contains(id)
    }

    /// Update the menu-bar title to reflect the current layout.
    func updateStatusTitle() {
        guard let src = inputManager.currentSource(),
              let name = inputManager.sourceName(src) else {
            statusItem?.button?.title = "⌨"
            return
        }
        // Show an abbreviated tag, e.g. "EN", "RU".
        let tag: String
        let lower = name.lowercased()
        if lower.contains("russian") || lower.contains("русск") {
            tag = "RU"
        } else if lower.contains("u.s.") || lower.contains("abc")
                    || lower.contains("british") || lower.contains("english") {
            tag = "EN"
        } else {
            // Use the first two letters of the name.
            tag = String(name.prefix(2)).uppercased()
        }
        statusItem?.button?.title = tag
    }

    @objc private func inputSourceDidChange() {
        InputLogger.shared.log(
            "LAYOUT changed to \(inputManager.currentSourceID() ?? "?")")
        updateStatusTitle()
        // Rebuild maps when sources change (e.g. user adds a layout).
        inputManager.rebuildMaps()
    }

    @objc private func activeAppDidChange(_ notification: Notification) {
        // Be conservative: the new app has its own caret and text.
        InputLogger.shared.log("APP switch -> clear token")
        frontmostBundleID =
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        clearTypedRun()
        resetWordBuffer()
        selectionLikely = false
        shiftTracker.reset()
        axEnabledPID = -1
        enableAccessibilityForFrontmostApp()
    }

    // ══════════════════════════════════════════════════════════
    // MARK: Accessibility
    // ══════════════════════════════════════════════════════════

    private func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
            as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        InputLogger.shared.log("ACCESSIBILITY trusted=\(trusted ? 1 : 0)")
        if !trusted {
            NSLog("[SalukaKey] Accessibility permission not yet granted. "
                + "Some features will not work until you approve it "
                + "in System Settings.")
        }
    }

    // ══════════════════════════════════════════════════════════
    // MARK: Event tap
    // ══════════════════════════════════════════════════════════

    private func installEventTap() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)

        // Use Unmanaged to pass `self` as the refcon pointer.
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Active tap: needed to swallow the boundary key while a
            // whole-word correction is being applied. The callback
            // returns the event unchanged unless it explicitly
            // consumed one.
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallbackFunc,
            userInfo: refcon
        ) else {
            InputLogger.shared.log("EVENT TAP create failed")
            return false
        }

        eventTap = tap
        let rlSrc = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = rlSrc
        CFRunLoopAddSource(CFRunLoopGetMain(), rlSrc, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    // ══════════════════════════════════════════════════════════
    // MARK: Event handling (called from the C callback)
    // ══════════════════════════════════════════════════════════

    /// Main entry point from the C event-tap callback.
    ///
    /// Returns `true` when the event must be swallowed (the caller
    /// then returns `nil` from the tap callback). Only whole-word
    /// boundary corrections consume an event; everything else is
    /// passed through untouched.
    @discardableResult
    func handleEvent(_ event: CGEvent, type: CGEventType) -> Bool {
        // Re-enable the tap if the system disabled it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            InputLogger.shared.log("EVENT TAP re-enabled (\(type))")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        }

        // Skip our own simulated events.
        if event.getIntegerValueField(.eventSourceUserData)
            == kSimulatedEventMarker {
            return false
        }
        if isSimulating { return false }

        // Never read, log or rewrite anything while a password field
        // has secure input enabled.
        if IsSecureEventInputEnabled() { return false }

        // Fully excluded app: SalukaKey does nothing at all.
        if isExcludedFrontmostApp() { return false }

        // Master switch: only single-Shift layout cycling remains.
        // Do not touch word buffers, selections or the pasteboard.
        if allFunctionsDisabled {
            switch type {
            case .flagsChanged:
                handleFlagsChanged(event)
            case .keyDown:
                // Still needed so Shift+letter is not mistaken for a
                // clean Shift tap.
                shiftTracker.keyDown()
            default:
                break
            }
            return false
        }

        switch type {
        case .flagsChanged:
            handleFlagsChanged(event)
            return false
        case .keyDown:
            return handleKeyDown(event)
        case .leftMouseDown:
            // A click can move the caret anywhere — forget what was
            // typed before it. A double-click or Shift+click is a
            // word/range selection, so remember that for double-Shift.
            let clickCount = event.getIntegerValueField(
                .mouseEventClickState)
            let extending = event.flags.contains(.maskShift)
            selectionLikely = clickCount >= 2 || extending
            InputLogger.shared.log(
                "MOUSE click count=\(clickCount) "
                + "shift=\(extending ? 1 : 0) "
                + "selection=\(selectionLikely ? 1 : 0)")
            clearTypedRun()
            resetWordBuffer()
            return false
        case .leftMouseDragged:
            // Dragging is how a selection is made with the mouse.
            selectionLikely = true
            return false
        case .rightMouseDown, .otherMouseDown:
            InputLogger.shared.log("MOUSE click -> clear token")
            selectionLikely = false
            clearTypedRun()
            resetWordBuffer()
            return false
        default:
            return false
        }
    }

    // ── Flags changed (Shift tracking) ───────────────────────

    private func handleFlagsChanged(_ event: CGEvent) {
        let flags = event.flags
        let shiftPressed = flags.contains(.maskShift)
        let wasDown = shiftTracker.isShiftDown

        let gesture = shiftTracker.flagsChanged(shiftPressed: shiftPressed)

        if shiftPressed != wasDown {
            InputLogger.shared.log(
                "SHIFT \(shiftPressed ? "down" : "up") "
                + "gesture=\(gesture) "
                + "layout=\(inputManager.currentSourceID() ?? "?")")
        }

        switch gesture {
        case .none:
            break
        case .singleShift:
            performSingleShift()
        case .doubleShift:
            performDoubleShift()
        }
    }

    // ── Key down (word buffer + auto-switch) ─────────────────

    /// Resolve the typed character through the current layout's map.
    ///
    /// **Never trust the CGEvent's Unicode string for plain keys.**
    /// On macOS an event's `keyboardGetUnicodeString` is filled using
    /// the *global / WindowServer* layout, while every app may have
    /// its own per-app input source. When those disagree (Chrome,
    /// VS Code, etc.) the event string describes a character the
    /// focused app never received. The keycode + TIS source is the
    /// only description that matches what the focused app inserts.
    ///
    /// Option/Cmd/Ctrl combinations (dead keys, accents, shortcuts)
    /// fall back to the event's string.
    private func resolvedCharacter(keyCode: UInt16,
                                   flags: CGEventFlags,
                                   eventChar: Character?) -> Character? {
        guard !flags.contains(.maskAlternate),
              !flags.contains(.maskCommand),
              !flags.contains(.maskControl) else { return eventChar }

        guard let layoutID = inputManager.currentSourceID(),
              let mapped = inputManager.character(
                  forKeyCode: keyCode,
                  shifted: flags.contains(.maskShift),
                  inSourceID: layoutID)
        else { return eventChar }

        if flags.contains(.maskAlphaShift), mapped.isLetter {
            // Caps Lock toggles the case. With Shift held the map
            // already gives an uppercase letter, so Caps Lock makes
            // it lowercase again.
            let text = String(mapped)
            let toggled = mapped.isUppercase
                ? text.lowercased()
                : text.uppercased()
            return toggled.first ?? mapped
        }
        return mapped
    }

    private func handleKeyDown(_ event: CGEvent) -> Bool {
        // Tell the shift tracker that a key was pressed.
        shiftTracker.keyDown()

        let keyCode = UInt16(event.getIntegerValueField(
            .keyboardEventKeycode))
        let flags = event.flags

        // Extract the unicode character before the special-key
        // handling, so the log also records Backspace/arrows/Return.
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(
            maxStringLength: 4,
            actualStringLength: &length,
            unicodeString: &chars)
        let eventChar: Character? = length > 0
            ? String(utf16CodeUnits: chars, count: length).first
            : nil
        let ch = resolvedCharacter(keyCode: keyCode,
                                   flags: flags,
                                   eventChar: eventChar)

        let token = String(typedRun.map { $0.character })
        let word = String(wordBuffer.map { $0.character })
        InputLogger.shared.log(
            "KEY kc=\(keyCode) char=\(eventChar.map(debugChar) ?? "-")"
            + " mapped=\(ch.map(debugChar) ?? "-")"
            + " shift=\(flags.contains(.maskShift) ? 1 : 0)"
            + " caps=\(flags.contains(.maskAlphaShift) ? 1 : 0)"
            + " cmd=\(flags.contains(.maskCommand) ? 1 : 0)"
            + " opt=\(flags.contains(.maskAlternate) ? 1 : 0)"
            + " ctrl=\(flags.contains(.maskControl) ? 1 : 0)"
            + " layout=\(inputManager.currentSourceID() ?? "?")"
            + " word=\(String(reflecting: word))"
            + " token=\(String(reflecting: token))")

        // Track whether the user just made a selection. This is the
        // safe signal for Chrome/Electron, which do not expose
        // AXSelectedText: only then may we copy the selection with
        // ⌘C. In editors such as VS Code, ⌘C without a selection
        // copies the whole line, so this flag must be accurate.
        let extendsSelection: Bool
        switch keyCode {
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            extendsSelection = true
        default:
            extendsSelection = false
        }
        if flags.contains(.maskCommand) {
            if keyCode == kVK_ANSI_A {
                selectionLikely = true          // ⌘A
            } else if keyCode == kVK_ANSI_C {
                // ⌘C does not change the selection; keep the flag.
            } else if flags.contains(.maskShift) && extendsSelection {
                selectionLikely = true          // ⌘⇧← etc.
            } else {
                selectionLikely = false
            }
        } else if flags.contains(.maskShift) && extendsSelection {
            selectionLikely = true              // ⇧← etc.
        } else {
            // Any other key (letter, space, Backspace, plain arrow…)
            // replaces or collapses the selection.
            selectionLikely = false
        }

        // Command / Control shortcuts can move the caret, change the
        // document, or invoke a menu — our idea of "what was typed
        // last" is no longer reliable.
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            InputLogger.shared.log("KEY cmd/ctrl -> clear token")
            clearTypedRun()
            resetWordBuffer()
            return false
        }

        switch keyCode {
        case kVK_Delete:
            // Plain Backspace removes one remembered character.
            // Option+Backspace deletes a whole word, so we can no
            // longer know how much is left — forget the run.
            if flags.contains(.maskAlternate) {
                clearTypedRun()
                InputLogger.shared.log(
                    "BACKSPACE option -> clear token")
            } else if !typedRun.isEmpty {
                typedRun.removeLast()
                InputLogger.shared.log(
                    "BACKSPACE -> token="
                    + String(reflecting: String(
                        typedRun.map { $0.character })))
            }
            resetWordBuffer()
            return false
        case kVK_ForwardDelete,
             kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
             kVK_Return, kVK_KeypadEnter, kVK_Tab, kVK_Escape:
            InputLogger.shared.log(
                "BOUNDARY kc=\(keyCode) -> clear token")
            clearTypedRun()
            resetWordBuffer()
            return false
        default:
            break
        }

        guard let ch = ch else { return false }
        let shifted = flags.contains(.maskShift)

        // A letter belongs to the current word.
        if ch.isLetter {
            // Remember what was typed, for double-Shift conversion.
            noteTypedCharacter(ch, keyCode: keyCode, shifted: shifted)
            wordBuffer.append(KeyStroke(keyCode: keyCode,
                                        character: ch,
                                        shifted: shifted))
            // Run auto-switch heuristic. If it corrected the word,
            // the current key was swallowed and is already included
            // in the injected text.
            if !alreadySwitchedThisWord && checkAutoSwitch() {
                return true
            }
            return false
        }

        // Punctuation that is a letter in another layout belongs to
        // the token: ",ольшой" (leading), "nt,z" → "тебя" (internal),
        // or "привет," (trailing). The conversion helper decides
        // later whether to transliterate it.
        if !ch.isWhitespace && isPossibleLetterKey(keyCode,
                                                  shifted: shifted) {
            noteTypedCharacter(ch, keyCode: keyCode, shifted: shifted)
            if wordBuffer.isEmpty {
                if wordPrefixStrokes.isEmpty {
                    wordPrefixStrokes.append(
                        KeyStroke(keyCode: keyCode,
                                  character: ch,
                                  shifted: shifted))
                } else {
                    resetWordBuffer()
                }
            } else {
                wordBuffer.append(KeyStroke(keyCode: keyCode,
                                            character: ch,
                                            shifted: shifted))
            }
            return false
        }

        // A real boundary: whitespace or a symbol that is never a
        // letter on any enabled layout.
        if !wordBuffer.isEmpty && !alreadySwitchedThisWord {
            if finalizeWordAtBoundary(boundary: ch,
                                      keyCode: keyCode,
                                      shifted: shifted) {
                // The original boundary event is consumed; the
                // corrected word and the boundary character were
                // injected together.
                return true
            }
        }

        // Remember the boundary/symbol for double-Shift and history.
        noteTypedCharacter(ch, keyCode: keyCode, shifted: shifted)
        resetWordBuffer()
        return false
    }

    /// True when this physical key produces a letter in at least one
    /// enabled layout. Used to keep a leading "," / ";" / "[" around
    /// so it can be corrected into "б" / "ж" / "х" together with the
    /// word that follows it.
    private func isPossibleLetterKey(_ keyCode: UInt16,
                                     shifted: Bool) -> Bool {
        for map in inputManager.maps.values {
            let ch = shifted ? map.shifted[keyCode]
                             : map.unshifted[keyCode]
            if ch?.isLetter == true { return true }
        }
        return false
    }

    private func debugChar(_ ch: Character) -> String {
        String(reflecting: ch)
    }

    // ══════════════════════════════════════════════════════════
    // MARK: Single Shift → cycle layout
    // ══════════════════════════════════════════════════════════

    private func performSingleShift() {
        guard shiftSwitchEnabled else { return }
        let prevID = inputManager.currentSourceID()
        inputManager.cycleToNext()
        let newID = inputManager.currentSourceID()

        InputLogger.shared.log(
            "SINGLE-SHIFT \(prevID ?? "?") -> \(newID ?? "?")")

        if let p = prevID, let n = newID {
            lastSwitch = SwitchRecord(previousSourceID: p,
                                      newSourceID: n,
                                      timestamp: Date())
        }
        updateStatusTitle()
        resetWordBuffer()
    }

    // ══════════════════════════════════════════════════════════
    // MARK: Double Shift → transliterate or undo
    // ══════════════════════════════════════════════════════════

    private func performDoubleShift() {
        guard !allFunctionsDisabled else { return }
        // Let the second Shift release finish, then start the
        // copy → convert → paste sequence on the run loop.
        DispatchQueue.main.async { [weak self] in
            self?.startDoubleShiftConversion()
        }
    }

    /// Convert the current selection if there is one. Otherwise
    /// convert the last typed token. If neither exists, undo the
    /// switch.
    ///
    /// The selection is checked first: the user may double-Shift a
    /// word ten lines above, and converting the last token instead
    /// would be wrong. Reading it through Accessibility is safe even
    /// when there is no selection (unlike a ⌘C probe, which copies
    /// the whole line in VS Code).
    private func startDoubleShiftConversion() {
        // The first Shift of the pair already cycled the layout, so
        // this is the layout that was active while typing.
        let fallbackSourceID = lastSwitch?.previousSourceID
        let hadSelectionGesture = selectionLikely
        selectionLikely = false

        isSimulating = true
        enableAccessibilityForFrontmostApp()

        InputLogger.shared.log(
            "DBL start token="
            + String(reflecting: String(typedRun.map { $0.character }))
            + " fallback=\(fallbackSourceID ?? "?")"
            + " selectionGesture=\(hadSelectionGesture ? 1 : 0)")

        // ── 1. Accessibility can read the selection.
        if let selectedText = selectedTextViaAX() {
            if !selectedText.isEmpty {
                InputLogger.shared.log(
                    "DBL selection len=\(selectedText.count) "
                    + "text=\(String(reflecting: selectedText))")
                convertSelectionText(selectedText,
                                     preferredSourceID: fallbackSourceID,
                                     savedPB: nil)
                return
            }
            InputLogger.shared.log("DBL AX selection is empty")
        } else {
            InputLogger.shared.log("DBL AX selection unavailable")
        }

        // ── 2. Chrome/Electron: AX unavailable, but the user made a
        //       selection gesture. Copy it once; every write we make
        //       to the pasteboard carries transient markers.
        if hadSelectionGesture {
            tryCopySelectionThenContinue(
                fallbackSourceID: fallbackSourceID)
            return
        }

        // ── 3. No selection: last typed token, no clipboard.
        continueWithToken(fallbackSourceID: fallbackSourceID)
    }

    /// Copy the current selection with ⌘C, then convert it.
    ///
    /// Only called when a selection gesture was observed, so VS Code's
    /// "⌘C with no selection copies the current line" quirk cannot
    /// trigger a conversion by itself.
    private func tryCopySelectionThenContinue(
        fallbackSourceID: String?
    ) {
        let savedPB = PasteboardHelper.save()
        InputLogger.shared.log("DBL copying selection with Cmd+C")
        NSPasteboard.general.clearContents()
        KeySimulator.simulateCopy()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            [weak self] in
            guard let self = self else { return }

            if let text = PasteboardHelper.readString(), !text.isEmpty {
                InputLogger.shared.log(
                    "DBL copied selection len=\(text.count) "
                    + "text=\(String(reflecting: text))")
                self.convertSelectionText(
                    text,
                    preferredSourceID: fallbackSourceID,
                    savedPB: savedPB)
            } else {
                InputLogger.shared.log(
                    "DBL copied selection empty -> token")
                // We cleared the clipboard: put the user's item back.
                PasteboardHelper.restore(savedPB)
                self.continueWithToken(
                    fallbackSourceID: fallbackSourceID)
            }
        }
    }

    /// Convert a user selection.
    ///
    /// `savedPB` is non-nil only when a ⌘C probe was used; then the
    /// original clipboard must be restored even if AX handles the
    /// replacement.
    private func convertSelectionText(
        _ text: String,
        preferredSourceID: String?,
        savedPB: PasteboardHelper.Snapshot?
    ) {
        guard let pair = inputManager.conversionPair(
            for: text,
            preferredSourceID: preferredSourceID
        ) else {
            InputLogger.shared.log(
                "DBL no conversion pair for "
                + String(reflecting: text))
            if let savedPB { PasteboardHelper.restore(savedPB) }
            revertLayoutSwitch()
            return
        }

        let converted = inputManager.convertText(text,
                                                 from: pair.src,
                                                 to: pair.dst)
        InputLogger.shared.log(
            "DBL convert \(pair.src) -> \(pair.dst) "
            + "text=\(String(reflecting: text)) "
            + "converted=\(String(reflecting: converted))")

        // Preferred path: direct Accessibility replacement. It never
        // touches NSPasteboard and can keep the text selected.
        let result = replaceSelectedTextViaAX(converted)
        if result.replaced {
            InputLogger.shared.log(
                "DBL replaced selection via AX "
                + "selectionKept=\(result.selectionKept ? 1 : 0)")
            applyConvertedLayout(pair)
            setTypedRun(converted, sourceID: pair.dst)
            selectionLikely = result.selectionKept
            if let savedPB { PasteboardHelper.restore(savedPB) }
            endSimulation(after: 0.10)
            return
        }

        // Fallback: paste, with transient markers on every write.
        let snapshot = savedPB ?? PasteboardHelper.save()
        pasteSelection(converted, pair: pair, savedPB: snapshot)
    }

    /// Paste converted text over the current selection. Only used
    /// when Accessibility cannot write to the focused element.
    private func pasteSelection(
        _ converted: String,
        pair: (src: String, dst: String),
        savedPB: PasteboardHelper.Snapshot
    ) {
        applyConvertedLayout(pair)
        InputLogger.shared.log("DBL paste conversion (marked)")
        PasteboardHelper.writeString(converted)
        KeySimulator.simulatePaste()

        // A paste collapses the selection. Remember the pasted text
        // so the next double-Shift can still cycle it.
        setTypedRun(converted, sourceID: pair.dst)
        selectionLikely = false
        schedulePasteboardRestore(savedPB)
        endSimulation(after: 0.10)
    }

    /// The last-token path. It never touches the clipboard:
    /// Backspace the old token, type the new one as Unicode.
    private func continueWithToken(fallbackSourceID: String?) {
        guard let range = lastTokenRange() else {
            InputLogger.shared.log("DBL no selection, no token")
            revertLayoutSwitch()
            return
        }

        let token = Array(typedRun[range])
        guard !token.isEmpty else {
            revertLayoutSwitch()
            return
        }
        let tokenText = String(token.map { $0.character })
        let tokenSourceID = token.last?.sourceID ?? fallbackSourceID

        InputLogger.shared.log(
            "DBL token range=\(range.lowerBound)..<\(range.upperBound)"
            + " text=\(String(reflecting: tokenText))"
            + " source=\(tokenSourceID ?? "?")")

        convertLastToken(tokenText,
                         range: range,
                         preferredSourceID: tokenSourceID)
    }

    private func convertLastToken(
        _ token: String,
        range: Range<Int>,
        preferredSourceID: String?
    ) {
        guard let pair = inputManager.conversionPair(
            for: token,
            preferredSourceID: preferredSourceID
        ) else {
            InputLogger.shared.log(
                "DBL no conversion pair for "
                + String(reflecting: token))
            revertLayoutSwitch()
            return
        }

        let converted = inputManager.convertText(token,
                                                 from: pair.src,
                                                 to: pair.dst)
        InputLogger.shared.log(
            "DBL token-convert \(pair.src) -> \(pair.dst) "
            + "text=\(String(reflecting: token)) "
            + "converted=\(String(reflecting: converted))")

        applyConvertedLayout(pair)

        // The caret is after the token and any trailing spaces.
        // Move left over the spaces, Backspace the token, type the
        // converted text, then restore the caret after the spaces.
        let trailing = typedRun.count - range.upperBound
        for _ in 0..<trailing {
            KeySimulator.tap(keyCode: kVK_LeftArrow)
        }
        KeySimulator.simulateBackspace(count: token.count)
        KeySimulator.typeUnicode(converted)
        for _ in 0..<trailing {
            KeySimulator.tap(keyCode: kVK_RightArrow)
        }

        let replacement = converted.map {
            TypedChar(character: $0,
                      sourceID: pair.dst,
                      keyCode: 0,
                      shifted: false)
        }
        typedRun.replaceSubrange(range, with: replacement)

        InputLogger.shared.log(
            "DBL token-retype \(String(reflecting: converted))")
        endSimulation(after: 0.10)
    }

    /// Switch to the destination layout and remember the conversion
    /// for undo / the status item.
    private func applyConvertedLayout(_ pair: (src: String, dst: String)) {
        inputManager.selectByID(pair.dst)
        updateStatusTitle()
        lastSwitch = SwitchRecord(previousSourceID: pair.src,
                                  newSourceID: pair.dst,
                                  timestamp: Date())
    }

    /// Undo the first Shift's layout cycle when there was nothing to
    /// convert. Does not touch the pasteboard.
    private func revertLayoutSwitch() {
        if let record = lastSwitch {
            inputManager.selectByID(record.previousSourceID)
            lastSwitch = nil
            updateStatusTitle()
        }
        endSimulation(after: 0.02)
    }

    private func setTypedRun(_ text: String, sourceID: String?) {
        typedRun = text.map {
            TypedChar(character: $0,
                      sourceID: sourceID,
                      keyCode: 0,
                      shifted: false)
        }
    }

    /// The system-wide focused UI element, if Accessibility can
    /// provide it.
    private func focusedElementViaAX() -> AXUIElement? {
        enableAccessibilityForFrontmostApp()

        let systemWide = AXUIElementCreateSystemWide()
        // Never let a hung app block our event tap for long.
        AXUIElementSetMessagingTimeout(systemWide, 0.5)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                systemWide,
                kAXFocusedUIElementAttribute as CFString,
                &focusedRef) == .success,
              let focused = focusedRef,
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }

        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }

    /// Ask the frontmost app to expose its accessibility tree.
    ///
    /// Chromium/Electron keep web-content accessibility off until a
    /// client sets one of these attributes. `AXManualAccessibility`
    /// is the Chromium-specific switch, `AXEnhancedUserInterface`
    /// the AppKit-compatible one.
    private func enableAccessibilityForFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return
        }
        let pid = app.processIdentifier
        if axEnabledPID == pid { return }

        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        let s1 = AXUIElementSetAttributeValue(
            axApp,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue)
        let s2 = AXUIElementSetAttributeValue(
            axApp,
            "AXEnhancedUserInterface" as CFString,
            kCFBooleanTrue)
        if s1 == .success || s2 == .success {
            axEnabledPID = pid
        }
    }

    /// Selected text of the system-wide focused UI element.
    ///
    /// - Returns `""` when the app explicitly reports no selection.
    /// - Returns `nil` when the attribute is unavailable or the call
    ///   fails (unknown state — callers must not assume a selection).
    ///
    /// Chrome and Electron apps often do not expose `AXSelectedText`,
    /// even though they do expose `AXSelectedTextRange`. In that case
    /// ask for the substring by range, or slice the full `AXValue`.
    private func selectedTextViaAX() -> String? {
        guard let element = focusedElementViaAX() else { return nil }

        // 1. The standard attribute. Some apps return an empty
        //    string even when there is a selection, so an empty
        //    value is not conclusive.
        var selectedRef: CFTypeRef?
        let selectedStatus = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedRef)
        if selectedStatus == .success,
           let text = selectedRef as? String,
           !text.isEmpty {
            return text
        }

        // 2. Selected range. This is what Chromium exposes.
        guard let selection = selectedRangeViaAX(element) else {
            return selectedStatus == .success ? "" : nil
        }
        if selection.range.length == 0 { return "" }

        // 3. Ask the app for the substring directly.
        if let text = stringForRange(element, selection.value),
           !text.isEmpty {
            return text
        }

        // 4. Slice the full value with the selected range.
        if let full = stringAttribute(element,
                                      kAXValueAttribute as CFString),
           let text = substring(full, range: selection.range),
           !text.isEmpty {
            return text
        }

        // There is a selection, but it cannot be read through AX.
        // Return nil so the caller can try a safe copy fallback.
        return nil
    }

    /// `AXSelectedTextRange` of the focused element.
    private func selectedRangeViaAX(_ element: AXUIElement)
        -> (range: CFRange, value: CFTypeRef)? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                &ref) == .success,
              let value = ref,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }

        let axValue = value as! AXValue
        var range = CFRange()
        let ok = withUnsafeMutablePointer(to: &range) {
            AXValueGetValue(axValue, .cfRange, $0)
        }
        guard ok else { return nil }
        return (range, value)
    }

    /// `AXStringForRange` for a previously read selected range.
    private func stringForRange(_ element: AXUIElement,
                                _ rangeValue: CFTypeRef) -> String? {
        var ref: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &ref)
        guard status == .success, let value = ref else { return nil }
        return value as? String
    }

    private func stringAttribute(_ element: AXUIElement,
                                 _ name: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &ref) == .success,
              let value = ref else { return nil }
        return value as? String
    }

    private func substring(_ full: String, range: CFRange) -> String? {
        let ns = full as NSString
        guard range.location >= 0, range.length >= 0,
              range.location + range.length <= ns.length else {
            return nil
        }
        return ns.substring(
            with: NSRange(location: range.location, length: range.length))
    }

    /// Whether `value` contains exactly `text` at a UTF-16 location.
    private func valueContains(_ value: String,
                               at location: CFIndex,
                               text: String) -> Bool {
        let ns = value as NSString
        let length = text.utf16.count
        guard location >= 0, length >= 0,
              location + length <= ns.length else { return false }
        let sub = ns.substring(
            with: NSRange(location: location, length: length))
        return sub == text
    }

    /// Replace the current selection directly through Accessibility.
    ///
    /// This avoids the clipboard and ⌘V entirely. Some AppKit text
    /// views paste twice when a ⌘V arrives while an existing
    /// user-made selection is active; setting `AXSelectedText` is
    /// atomic and does not have that problem.
    ///
    /// The returned `selectionKept` says whether the new text was
    /// left selected. That is what makes a second double-Shift
    /// convert the same word back.
    private func replaceSelectedTextViaAX(_ text: String)
        -> (replaced: Bool, selectionKept: Bool) {
        guard let element = focusedElementViaAX() else {
            return (false, false)
        }

        let oldRange = selectedRangeViaAX(element)?.range
        let beforeValue = stringAttribute(element,
                                          kAXValueAttribute as CFString)
        let status = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef)
        guard status == .success else { return (false, false) }

        // Some apps (notably Chromium/Electron) return success for
        // AXSelectedText but do not change the document. Verify the
        // write and fall back to the marked paste path if it was
        // ignored.
        let afterValue = stringAttribute(element,
                                         kAXValueAttribute as CFString)
        let readBack = selectedTextViaAX()

        var applied = (readBack == text)
        if !applied, let old = oldRange, let after = afterValue,
           beforeValue != after,
           valueContains(after, at: old.location, text: text) {
            applied = true
        }
        guard applied else {
            InputLogger.shared.log(
                "AX write ignored -> marked paste fallback")
            return (false, false)
        }

        guard let old = oldRange else { return (true, false) }

        var newRange = CFRange(location: old.location,
                               length: text.utf16.count)
        guard let axRange = withUnsafePointer(to: &newRange, {
            AXValueCreate(.cfRange, $0)
        }) else { return (true, false) }

        let rangeStatus = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            axRange)
        return (true, rangeStatus == .success)
    }

    private func endSimulation(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            [weak self] in
            self?.isSimulating = false
        }
    }

    /// Give the frontmost app time to consume the synthetic ⌘V before
    /// restoring the user's clipboard.
    private func schedulePasteboardRestore(
        _ snapshot: PasteboardHelper.Snapshot
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            PasteboardHelper.restore(snapshot)
        }
    }

    // ══════════════════════════════════════════════════════════
    // MARK: Auto-switch while typing
    // ══════════════════════════════════════════════════════════

    private func checkAutoSwitch() -> Bool {
        guard autoSwitchEnabled,
              !allFunctionsDisabled,
              let curID = inputManager.currentSourceID() else {
            return false
        }

        guard let decision = LanguageHeuristics.suggestedLayout(
            buffer: wordPrefixStrokes + wordBuffer,
            currentSourceID: curID,
            mgr: inputManager
        ) else { return false }

        InputLogger.shared.log(decision.trace)

        guard let targetID = decision.targetID,
              targetID != curID else { return false }

        return applyAutoSwitch(to: targetID)
    }

    /// Replace the current word synchronously.
    ///
    /// Called from inside the event-tap callback, after the current
    /// letter was appended to `wordBuffer` but **before** the current
    /// key event reaches the app. The previous letters are in the
    /// document; the current one is not. We delete the previous
    /// letters, then insert the whole corrected word as Unicode. The
    /// current key event is swallowed by returning `true`, so no
    /// character is doubled and no other key can slip into the middle
    /// of the correction.
    private func applyAutoSwitch(to targetID: String) -> Bool {
        guard let curID = inputManager.currentSourceID(),
              curID != targetID else { return false }

        // The prefix may include a leading punctuation key that is a
        // letter in the other layout (",ольшой" → "большой"). The
        // word buffer itself may contain internal punctuation keys
        // ("nt,z" → "тебя").
        let strokes = wordPrefixStrokes + wordBuffer
        guard !strokes.isEmpty else { return false }

        let correctedText = correctedToken(strokes, to: targetID)
        guard !correctedText.isEmpty else { return false }

        InputLogger.shared.log(
            "AUTO-SWITCH \(curID) -> \(targetID) token="
            + String(reflecting: String(strokes.map { $0.character }))
            + " corrected=\(String(reflecting: correctedText))")

        let switched = inputManager.selectByID(targetID)
        updateStatusTitle()
        guard switched else {
            // Leave the word alone; the boundary check can still fix
            // it when the word is finished.
            InputLogger.shared.log(
                "AUTO-SWITCH-FAILED \(curID) -> \(targetID)")
            return false
        }

        // Remember the switch so double-Shift can undo it.
        lastSwitch = SwitchRecord(previousSourceID: curID,
                                  newSourceID: targetID,
                                  timestamp: Date())
        alreadySwitchedThisWord = true

        // The current letter has not reached the app yet.
        let deleteCount = strokes.count - 1
        if deleteCount > 0 {
            KeySimulator.simulateBackspace(count: deleteCount)
        }
        KeySimulator.typeUnicode(correctedText)

        // Update the letter buffer with the corrected characters.
        // The current token ends in a letter, so every punctuation
        // inside it is leading or internal and becomes a letter.
        wordBuffer = wordBuffer.compactMap { s in
            guard let ch = targetCharacter(for: s, in: targetID)
            else { return nil }
            return KeyStroke(keyCode: s.keyCode,
                             character: ch,
                             shifted: s.shifted,
                             uppercase: ch.isUppercase)
        }

        // Keep the typed-token history in sync. It already contains
        // the current letter, which the document did not receive.
        if typedRun.count >= strokes.count {
            let tail = typedRun.suffix(strokes.count)
            let tailText = String(tail.map { $0.character })
            let expected = String(strokes.map { $0.character })

            if tailText == expected {
                let replacement = zip(strokes, correctedText).map {
                    pair -> TypedChar in
                    let (s, ch) = pair
                    return TypedChar(character: ch,
                                     sourceID: targetID,
                                     keyCode: s.keyCode,
                                     shifted: s.shifted)
                }
                typedRun.removeLast(strokes.count)
                typedRun.append(contentsOf: replacement)
            } else {
                clearTypedRun()
            }
        }

        InputLogger.shared.log(
            "AUTO-RETYPE token=\(String(reflecting: correctedText))")

        // Swallow the current key: the corrected word already
        // includes it.
        return true
    }

    /// Convert a token by physical key position.
    ///
    /// Letters always transliterate. A punctuation key that is a
    /// letter in the target layout also transliterates when it is
    /// leading or internal; trailing punctuation is kept
    /// (`ghbdtn,` → `привет,`, while `nt,z` → `тебя`).
    private func correctedToken(_ strokes: [KeyStroke],
                                to targetID: String) -> String {
        let lastLetterIndex = strokes.lastIndex {
            $0.character.isLetter
        }
        var out = ""
        for (index, stroke) in strokes.enumerated() {
            if stroke.character.isLetter {
                out.append(targetCharacter(for: stroke, in: targetID)
                    ?? stroke.character)
                continue
            }
            if let last = lastLetterIndex, index > last {
                // Trailing punctuation stays punctuation.
                out.append(stroke.character)
                continue
            }
            let mapped = targetCharacter(for: stroke, in: targetID)
            if let mapped, mapped.isLetter {
                out.append(mapped)
            } else {
                out.append(stroke.character)
            }
        }
        return out
    }

    /// Map a stroke into `targetID`, preserving the produced case.
    ///
    /// `shifted` is the physical Shift state; `uppercase` is the case
    /// the user actually saw, which Caps Lock can flip independently.
    /// For a punctuation key that becomes a letter ("," → "б",
    /// ":" → "Ж"), the Shift state decides the case.
    private func targetCharacter(for stroke: KeyStroke,
                                 in targetID: String) -> Character? {
        guard let base = inputManager.character(
            forKeyCode: stroke.keyCode,
            shifted: stroke.shifted,
            inSourceID: targetID) else { return nil }
        guard base.isLetter else { return base }
        let text = String(base)
        let cased = stroke.uppercase ? text.uppercased()
                                     : text.lowercased()
        return cased.first ?? base
    }

    /// Whole-word check on space/punctuation.
    ///
    /// The boundary key has not been delivered to the app yet (the
    /// active event tap runs before it). If the finished word is a
    /// misspelling in the current language and a real word in another
    /// layout, we swallow the boundary, delete the word, and inject
    /// the corrected word plus the boundary character as Unicode.
    private func finalizeWordAtBoundary(boundary: Character,
                                        keyCode: UInt16,
                                        shifted: Bool) -> Bool {
        guard autoSwitchEnabled,
              !allFunctionsDisabled,
              let curID = inputManager.currentSourceID() else {
            return false
        }
        let strokes = wordPrefixStrokes + wordBuffer
        guard !strokes.isEmpty else { return false }

        // The document must still contain exactly the token we think
        // it contains; otherwise a click/autocorrect moved the caret.
        guard typedRun.count >= strokes.count else { return false }
        let tail = typedRun.suffix(strokes.count)
        let expected = String(strokes.map { $0.character })
        guard String(tail.map { $0.character }) == expected else {
            InputLogger.shared.log("BOUNDARY skip: token history mismatch")
            return false
        }

        guard let decision = LanguageHeuristics.suggestedLayout(
            buffer: strokes,
            currentSourceID: curID,
            mgr: inputManager,
            atBoundary: true
        ) else { return false }

        InputLogger.shared.log(decision.trace)

        guard let targetID = decision.targetID, targetID != curID else {
            return false
        }

        let corrected = correctedToken(strokes, to: targetID)
        guard !corrected.isEmpty else { return false }

        InputLogger.shared.log(
            "BOUNDARY-SWITCH \(curID) -> \(targetID) token="
            + String(reflecting: expected)
            + " corrected=\(String(reflecting: corrected))"
            + " boundary=\(String(reflecting: String(boundary)))")

        lastSwitch = SwitchRecord(previousSourceID: curID,
                                  newSourceID: targetID,
                                  timestamp: Date())

        let switched = inputManager.selectByID(targetID)
        updateStatusTitle()
        if !switched {
            InputLogger.shared.log(
                "BOUNDARY-SWITCH-FAILED \(curID) -> \(targetID)")
        }

        // The boundary event is consumed, so the caret is still right
        // after the last letter of the token.
        KeySimulator.simulateBackspace(count: strokes.count)
        KeySimulator.typeUnicode(corrected + String(boundary))

        // Replace the token in the history. Trailing punctuation was
        // kept by `correctedToken`, internal/leading letter-keys were
        // transliterated.
        let replacement = zip(strokes, corrected).map {
            pair -> TypedChar in
            let (s, ch) = pair
            return TypedChar(character: ch,
                             sourceID: targetID,
                             keyCode: s.keyCode,
                             shifted: s.shifted)
        }
        typedRun.removeLast(strokes.count)
        typedRun.append(contentsOf: replacement)
        typedRun.append(TypedChar(character: boundary,
                                  sourceID: targetID,
                                  keyCode: keyCode,
                                  shifted: shifted))

        InputLogger.shared.log(
            "BOUNDARY-RETYPE token="
            + String(reflecting: corrected + String(boundary)))

        resetWordBuffer()
        return true
    }

    private func resetWordBuffer() {
        wordBuffer.removeAll()
        wordPrefixStrokes.removeAll()
        alreadySwitchedThisWord = false
    }

    // ── Last typed token helpers ─────────────────────────────

    private func noteTypedCharacter(_ ch: Character,
                                    keyCode: UInt16,
                                    shifted: Bool) {
        typedRun.append(TypedChar(
            character: ch,
            sourceID: inputManager.currentSourceID(),
            keyCode: keyCode,
            shifted: shifted))

        // Keep the history bounded.
        if typedRun.count > 128 {
            typedRun.removeFirst(typedRun.count - 128)
        }
    }

    private func clearTypedRun() {
        typedRun.removeAll()
    }

    /// The last contiguous non-whitespace run in `typedRun`.
    /// Trailing spaces are skipped, so "привет " still yields "привет".
    private func lastTokenRange() -> Range<Int>? {
        var end = typedRun.count
        while end > 0 && typedRun[end - 1].character.isWhitespace {
            end -= 1
        }
        guard end > 0 else { return nil }

        var start = end
        while start > 0 && !typedRun[start - 1].character.isWhitespace {
            start -= 1
        }
        return start..<end
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - About Window
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Compact native About window: app icon, name, version, and a button
/// that opens the GitHub releases page.
final class AboutWindowController: NSWindowController {

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 340),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "About SalukaKey"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.center()
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildContent() {
        guard let window = window,
              let content = window.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(
                equalTo: content.topAnchor, constant: 30),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: content.bottomAnchor, constant: -18),
        ])

        let iconView = NSImageView()
        if let iconURL = Bundle.main.url(forResource: "AppIcon",
                                         withExtension: "icns"),
           let image = NSImage(contentsOf: iconURL) {
            iconView.image = image
        } else if let appIcon = NSApp.applicationIconImage {
            iconView.image = appIcon
        } else if let symbol = NSImage(
            systemSymbolName: "keyboard",
            accessibilityDescription: "SalukaKey") {
            iconView.image = symbol
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 96).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 96).isActive = true
        stack.addArrangedSubview(iconView)
        stack.setCustomSpacing(12, after: iconView)

        let name = NSTextField(labelWithString: "SalukaKey")
        name.font = .systemFont(ofSize: 22, weight: .semibold)
        name.alignment = .center
        stack.addArrangedSubview(name)

        let shortVersion =
            Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "1.1.0"
        let version = NSTextField(labelWithString: "v\(shortVersion)")
        version.font = .systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor
        version.alignment = .center
        stack.addArrangedSubview(version)

        let subtitle = NSTextField(
            wrappingLabelWithString:
                "Automatic keyboard layout switcher for macOS")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 2
        stack.addArrangedSubview(subtitle)
        stack.setCustomSpacing(16, after: subtitle)

        let updates = NSButton(
            title: "Check GitHub for Updates...",
            target: self,
            action: #selector(checkForUpdates))
        updates.bezelStyle = .rounded
        updates.controlSize = .regular
        stack.addArrangedSubview(updates)

        let copyright = NSTextField(labelWithString: "© 2026 SalukaKey")
        copyright.font = .systemFont(ofSize: 10)
        copyright.textColor = .tertiaryLabelColor
        copyright.alignment = .center
        stack.addArrangedSubview(copyright)
    }

    @objc private func checkForUpdates() {
        NSWorkspace.shared.open(kGitHubReleasesURL)
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Exclusions Window
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Standard macOS-style list of applications where SalukaKey must not
/// intercept anything (not even single Shift).
final class ExclusionsWindowController: NSWindowController,
    NSTableViewDataSource, NSTableViewDelegate {

    /// Called after the persisted list changes.
    var onChange: (() -> Void)?

    private struct ExcludedApp {
        let bundleID: String
        let name: String
        let icon: NSImage
    }

    private let table = NSTableView()
    private let scrollView = NSScrollView()
    private let removeButton = NSButton()
    private var apps: [ExcludedApp] = []

    private static let bundleIDsKey = "ExcludedBundleIDs"

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 390),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "Программы исключения"
        window.isReleasedWhenClosed = false
        window.center()
        window.backgroundColor = .windowBackgroundColor
        super.init(window: window)
        buildContent()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // ── UI ──────────────────────────────────────────────────

    private func buildContent() {
        guard let window = window,
              let content = window.contentView else { return }

        let title = NSTextField(labelWithString: "Программы исключения")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(title)

        let subtitle = NSTextField(
            wrappingLabelWithString:
                "SalukaKey не будет перехватывать ввод в этих приложениях — "
                + "ни автопереключение, ни двойной Shift, ни одиночный Shift.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 3
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(subtitle)

        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("app"))
        column.title = "Приложение"
        column.width = 500
        table.addTableColumn(column)
        table.headerView = NSTableHeaderView()
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 44
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)

        let addButton = NSButton(
            title: "+",
            target: self,
            action: #selector(addApplications))
        addButton.bezelStyle = .texturedRounded
        addButton.toolTip = "Добавить приложения"
        addButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(addButton)

        removeButton.title = "−"
        removeButton.target = self
        removeButton.action = #selector(removeSelectedApplication)
        removeButton.bezelStyle = .texturedRounded
        removeButton.toolTip = "Убрать выбранное приложение"
        removeButton.isEnabled = false
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(removeButton)

        let doneButton = NSButton(
            title: "Готово",
            target: self,
            action: #selector(closeWindow))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(doneButton)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: 20),
            title.topAnchor.constraint(
                equalTo: content.topAnchor, constant: 18),

            subtitle.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: 20),
            subtitle.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -20),
            subtitle.topAnchor.constraint(
                equalTo: title.bottomAnchor, constant: 6),

            scrollView.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -20),
            scrollView.topAnchor.constraint(
                equalTo: subtitle.bottomAnchor, constant: 14),
            scrollView.heightAnchor.constraint(equalToConstant: 235),

            addButton.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: 20),
            addButton.topAnchor.constraint(
                equalTo: scrollView.bottomAnchor, constant: 12),
            addButton.widthAnchor.constraint(equalToConstant: 34),
            addButton.heightAnchor.constraint(equalToConstant: 26),

            removeButton.leadingAnchor.constraint(
                equalTo: addButton.trailingAnchor, constant: 8),
            removeButton.centerYAnchor.constraint(
                equalTo: addButton.centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 34),
            removeButton.heightAnchor.constraint(equalToConstant: 26),

            doneButton.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -20),
            doneButton.centerYAnchor.constraint(
                equalTo: addButton.centerYAnchor),
        ])
    }

    // ── Data ────────────────────────────────────────────────

    func refresh() {
        let ids = UserDefaults.standard.stringArray(
            forKey: Self.bundleIDsKey) ?? []
        apps = ids.map { id in
            let url = NSWorkspace.shared
                .urlForApplication(withBundleIdentifier: id)
            let bundle = url.flatMap { Bundle(url: $0) }
            let name = (bundle?.object(
                forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(
                    forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url?.deletingPathExtension().lastPathComponent
                ?? id
            let icon: NSImage
            if let url = url {
                icon = NSWorkspace.shared.icon(forFile: url.path)
            } else {
                icon = NSImage(named: NSImage.applicationIconName)
                    ?? NSImage()
            }
            return ExcludedApp(bundleID: id, name: name, icon: icon)
        }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name)
                == .orderedAscending
        }
        table.reloadData()
        removeButton.isEnabled = false
    }

    private func save(_ ids: Set<String>) {
        UserDefaults.standard.set(ids.sorted(),
                                  forKey: Self.bundleIDsKey)
        refresh()
        onChange?()
    }

    // ── Actions ─────────────────────────────────────────────

    @objc private func addApplications() {
        guard let window = window else { return }
        let panel = NSOpenPanel()
        panel.title = "Выберите приложения"
        panel.message =
            "SalukaKey не будет работать в выбранных приложениях."
        panel.prompt = "Добавить"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self = self else { return }
            var ids = Set(UserDefaults.standard.stringArray(
                forKey: Self.bundleIDsKey) ?? [])
            for url in panel.urls {
                if let id = Bundle(url: url)?.bundleIdentifier {
                    ids.insert(id)
                }
            }
            self.save(ids)
        }
    }

    @objc private func removeSelectedApplication() {
        let row = table.selectedRow
        guard row >= 0, row < apps.count else { return }
        var ids = Set(UserDefaults.standard.stringArray(
            forKey: Self.bundleIDsKey) ?? [])
        ids.remove(apps[row].bundleID)
        save(ids)
    }

    @objc private func closeWindow() {
        window?.close()
    }

    // ── Table ───────────────────────────────────────────────

    func numberOfRows(in tableView: NSTableView) -> Int {
        apps.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row >= 0, row < apps.count else { return nil }
        let app = apps[row]

        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier("AppCell")

        let icon = NSImageView()
        icon.image = app.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)

        let name = NSTextField(labelWithString: app.name)
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(name)

        let bundleID = NSTextField(labelWithString: app.bundleID)
        bundleID.font = .systemFont(ofSize: 10)
        bundleID.textColor = .secondaryLabelColor
        bundleID.lineBreakMode = .byTruncatingMiddle
        bundleID.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(bundleID)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(
                equalTo: cell.leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),

            name.leadingAnchor.constraint(
                equalTo: icon.trailingAnchor, constant: 8),
            name.trailingAnchor.constraint(
                equalTo: cell.trailingAnchor, constant: -6),
            name.topAnchor.constraint(
                equalTo: cell.centerYAnchor, constant: -15),

            bundleID.leadingAnchor.constraint(
                equalTo: name.leadingAnchor),
            bundleID.trailingAnchor.constraint(
                equalTo: cell.trailingAnchor, constant: -6),
            bundleID.topAnchor.constraint(
                equalTo: name.bottomAnchor, constant: 1),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = table.selectedRow >= 0
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - C Event Tap Callback
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Global (C-linkage-compatible) function pointer for CGEvent.tapCreate.
/// It bridges into the SalukaKeyApp instance via the refcon pointer.
private func eventTapCallbackFunc(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    if let refcon = refcon {
        let app = Unmanaged<SalukaKeyApp>.fromOpaque(refcon)
            .takeUnretainedValue()
        if app.handleEvent(event, type: type) {
            // Consumed (e.g. the boundary key of a whole-word
            // correction). The correction events were posted already.
            return nil
        }
    }
    // Pass the event through unchanged.
    return Unmanaged.passUnretained(event)
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Entry point
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let app = NSApplication.shared
// Regular app: icon in the Dock, plus the menu-bar layout indicator.
app.setActivationPolicy(.regular)

let delegate = SalukaKeyApp()
app.delegate = delegate

// Keep a global reference so the C callback can reach the instance
// (belt-and-suspenders alongside the refcon pointer).
gApp = delegate

app.run()
