import Foundation

// The stdout tables both spikes print, and the arithmetic that sizes them.
//
// They live here because both spikes need them and both had the same defect in
// their own copy. `columnWidth` sizes a column; `terminalColumn` renders a cell
// into it.

/// Renders one cell into a column of at least `width` characters.
///
/// **The trailing separator is the contract, not the padding.** A cell shorter
/// than its column is padded out to the full width; a cell exactly as long, or
/// longer, is returned whole with **one** space appended.
///
/// That last clause is what makes this safe for a column whose width is a
/// constant. `pad`-style rendering that returns the text untouched once it
/// reaches `width` looks fine while the literals happen to be short — and stops
/// being fine the day one grows. `kinsoku-language-tag-effect` against a
/// declared 24 printed as `kinsoku-language-tag-effectMEASURED`.
///
/// The cell is never truncated: half a value is worse than a long one, and the
/// values in these columns are hrefs and `cssSelector` strings.
///
/// **Known limitation:** the measurement is `String.count`, i.e. Character
/// count, and not terminal display width. A CJK value — `第一章`,
/// `韩立望着眼前` — counts 3 and 6 but renders at roughly twice that in a
/// monospaced terminal, so those rows still drift. Correcting it needs an East
/// Asian Width table; this is a log for a human, and the machine gate is the
/// JSON artifact.
public func terminalColumn(_ text: String, _ width: Int) -> String {
    text.count < width
        ? text + String(repeating: " ", count: width - text.count)
        : text + " "
}

/// The width of a column: its widest cell **plus the separator**, or `minimum`
/// as a floor.
///
/// `minimum` is whatever the column was declared as before it was measured, kept
/// so that a short table does not collapse. Pass every cell the column can
/// print, the header included.
public func columnWidth(_ minimum: Int, _ cells: [String]) -> Int {
    max(minimum, (cells.map(\.count).max() ?? 0) + 1)
}
