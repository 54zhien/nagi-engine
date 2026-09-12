import Foundation

/// Href comparison, kept separate because Readium normalises when **comparing**
/// and never when **storing** — which is one of the things this spike measures.
///
/// Readium's comparison helper is `Manifest.linkWithHREF`
/// (`Manifest.swift:137-157`): it tries `link.url().normalized.string ==
/// href.string`, then falls back to a query-and-fragment-stripped match, then
/// searches `alternates` and `children` recursively. A `Locator`'s synthesised
/// equality, by contrast, compares raw URLs — so `locator.href == manifestHref`
/// is not a safe test, and neither is `Locator.matchesAdjacentPageOrigin`,
/// which starts with a raw `href == other.href` guard
/// (`EPUBNavigatorViewController.swift:2552`).
///
/// **Fidelity gap, stated rather than hidden.** `AnyURL.normalized` is
/// "lowercase scheme + `path.normalizedPath`" (`URLProtocol.swift:34-39`), and
/// the body of `normalizedPath` was not reproduced here. What follows is the
/// mechanical part — scheme case, query and fragment removal, fragment
/// percent-decoding — and it deliberately leaves path-segment resolution alone
/// rather than inventing rules that were never read.
public enum Href {
    /// The href without its fragment.
    public static func removingFragment(_ href: String) -> String {
        guard let index = href.firstIndex(of: "#") else { return href }
        return String(href[..<index])
    }

    /// The href without its query or fragment.
    public static func removingQueryAndFragment(_ href: String) -> String {
        var result = removingFragment(href)
        if let index = result.firstIndex(of: "?") {
            result = String(result[..<index])
        }
        return result
    }

    /// The fragment, percent-decoded. Readium decodes it on read
    /// (`URLProtocol.swift:125-127`) — which matters, because a fragment is the
    /// usual carrier of a DOM id and ids are compared as text.
    public static func fragment(of href: String) -> String? {
        guard let index = href.firstIndex(of: "#") else { return nil }
        let raw = String(href[href.index(after: index)...])
        return raw.removingPercentEncoding ?? raw
    }

    /// Lowercases the scheme, if there is one. The path is left alone — see the
    /// fidelity note above.
    public static func normalized(_ href: String) -> String {
        guard let separator = href.range(of: "://") else { return href }
        return href[..<separator.lowerBound].lowercased() + href[separator.lowerBound...]
    }

    /// Whether two hrefs name the same resource, under the rules above: exact
    /// match first, then with query and fragment stripped — the same order
    /// `Manifest.linkWithHREF` uses.
    public static func isEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalized(lhs)
        let right = normalized(rhs)
        if left == right { return true }
        return removingQueryAndFragment(left) == removingQueryAndFragment(right)
    }
}
