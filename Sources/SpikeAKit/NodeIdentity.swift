import Foundation

/// ADR-0003's NodeID ladder, implemented only as far down as this spike needs.
///
/// The ladder has five rungs; two are here:
///
///   1. an explicit source id (`id=` / `xml:id=`)
///   2. a source-local stable anchor — a DOM path
///
/// The remaining three (parent identity + kind + fingerprint, source position,
/// and `sameFingerprintOrdinal`) are **not** implemented. They are also not
/// needed to measure what Spike A measures, because the fixture is built to show
/// where these two rungs run out — which is the evidence ADR-0003 needs.
///
/// A path is a legitimate rung rather than a disguised array index: it **is**
/// ladder rung 2 in ADR-0003 ("Source-local stable anchor（DOM path / XML path /
/// TXT source range）"). What the ADR forbids is using *parse order* as
/// identity; a path is a structural position in the source, and it is stable
/// for a given artifact.
public enum NodeID: Codable, Sendable, Hashable {
    case explicitID(String)
    case path([UInt32])

    /// The string form used in the report. Kept explicit so a reader of the
    /// artifact can tell the two rungs apart at a glance.
    public var described: String {
        switch self {
        case .explicitID(let id): return "id:\(id)"
        case .path(let path): return "path:" + path.map(String.init).joined(separator: "/")
        }
    }
}

/// Native Position: the precise coordinate inside Nagi's own layout.
///
/// ADR-0004 defines it as `unitID + nodeID + UTF-16 offset`, and CONTEXT.md
/// pins the offset to "canonical primary text 的 UTF-16 偏移" — so the offset is
/// **absolute within the unit's canonical text**, not relative to the node.
///
/// Both parts earn their place. The `nodeID` is the identity that has to survive
/// a re-parse; the offset is the precision that a selection or an annotation
/// needs. Losing either makes a different thing: drop the nodeID and a re-parse
/// can only re-derive the position by offset, which shifts the moment any text
/// before it changes; drop the offset and a position can only name a block.
public struct NativePosition: Codable, Sendable, Hashable {
    public var unitID: String
    public var nodeID: NodeID
    public var utf16Offset: Int

    public init(unitID: String, nodeID: NodeID, utf16Offset: Int) {
        self.unitID = unitID
        self.nodeID = nodeID
        self.utf16Offset = utf16Offset
    }
}
