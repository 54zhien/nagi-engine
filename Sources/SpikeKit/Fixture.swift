import Foundation

/// The probe corpus.
///
/// Embedded as source rather than loaded from a file so that the first CI run
/// has no resource-path failure mode. The real corpus (untrusted, real-world
/// EPUBs across vendors) arrives with the document layer, not here.
///
/// The corpus is deliberately built around the boundary conditions that matter,
/// and the probes sweep the measure width rather than trying to hand-place a
/// prohibited character at a line edge. Hand-placed cases go stale the moment
/// the font changes; a sweep cannot.
public enum Fixture {
    public static let name = "kinsoku-v1"

    /// Body text. Long enough to produce many lines at every swept width.
    ///
    /// Contains, intentionally:
    ///   - 行頭禁則 candidates: 、。」）！？ーっゃゅょ
    ///   - 行末禁則 candidates: 「（『
    ///   - adjacent punctuation pairs: 」。 and 、「
    ///   - mixed CJK/Latin so autospace and font fallback are exercised
    ///   - a paragraph with 漢字 and digits
    public static let body = """
    韩立望着眼前的山谷，沉默了片刻。「这里就是传说中的灵界入口吗？」他低声问道。
    山谷之中云雾缭绕，隐约可以听见流水的声音。他缓缓向前走去，脚下的碎石发出细碎的响声。
    走了大约三百步之后，他停下了。前方的石壁上刻着一些古老的文字，虽然年代久远，但依然清晰可辨。
    他伸出手，轻轻触摸那些文字。就在指尖接触石壁的一瞬间，一股奇异的力量沿着手臂传来。
    「原来如此。」他喃喃自语，「难怪师父说，这个地方只有筑基期以上的修士才能进入。」
    他收回手，从怀中取出一枚玉简，仔细地对照着上面的记载。玉简上的文字与石壁上的大体一致，
    只是在末尾多了一行小字：「入者慎之，出者亦慎之。」
    韩立沉吟良久，最终还是迈出了那一步。他知道，从这一刻起，自己已经没有回头的余地了。
    The quick brown fox jumps over the lazy dog. ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789.
    """

    /// Characters that must not begin a line (行頭禁則).
    public static let prohibitedAtLineStart: Set<Character> = [
        "、", "。", "，", "．", "！", "？", "：", "；",
        "）", "」", "』", "】", "〕", "》", "〉", "”", "’",
        "ー", "ぁ", "ぃ", "ぅ", "ぇ", "ぉ", "っ", "ゃ", "ゅ", "ょ", "ゎ", "々"
    ]

    /// Characters that must not end a line (行末禁則).
    public static let prohibitedAtLineEnd: Set<Character> = [
        "（", "「", "『", "【", "〔", "《", "〈", "“", "‘"
    ]

    /// Base and annotation for the ruby probe. Written as a bare pair so the
    /// probe does not depend on any HTML parsing.
    public static let rubyBase = "東京"
    public static let rubyAnnotation = "とうきょう"

    /// A line for the ruby probe: surrounding text plus an annotated span, so
    /// the measurement can tell whether ruby adds height or overlaps neighbours.
    public static let rubyContextPrefix = "彼は"
    public static let rubyContextSuffix = "へ行った。"

    /// Everything the glyph-coverage probe should check for presence in the font.
    public static var coverageSample: [Character] {
        var seen = Set<Character>()
        var ordered: [Character] = []
        for ch in body + rubyBase + rubyAnnotation + rubyContextPrefix + rubyContextSuffix {
            if ch == "\n" { continue }
            if seen.insert(ch).inserted { ordered.append(ch) }
        }
        for ch in prohibitedAtLineStart.union(prohibitedAtLineEnd).sorted() {
            if seen.insert(ch).inserted { ordered.append(ch) }
        }
        return ordered
    }
}
