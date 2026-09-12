import Foundation
import SpikeKit

/// The one place a probe decides whether it is allowed to conclude anything.
///
/// > **A probe may conclude `yes` or `no` only if its discriminating arm has
/// > non-zero evidence. Zero coverage is `inconclusive`, never success.**
///
/// This package has reached that failure twice. `native-path-anchored` was the
/// only row exercising the progression path and had **no test at all**, which is
/// how it stayed classified `.exact` for a round with nobody noticing. Then
/// `progress-provenance`'s carrier arm reported `yes` while `carriedRows` was
/// zero — it passed by having nothing that could fail.
///
/// Both are the same shape: a rule whose first clause is vacuously true. Kept
/// pure and separate from the probes for the same reason `Kinsoku.assess` is
/// (`SpikeKit/Typography.swift`): the rule is the part that was wrong, and a
/// rule living inside a fixture-dependent probe cannot be tested.
///
/// It lives here rather than as a declared field on `ProbeOutcome` because that
/// type is in `SpikeKit` and carries Spike B's sealed payload and fingerprint;
/// nothing about this rule needs that price paid.
public enum ProbeEvidence {

    /// - Parameters:
    ///   - observed: how many samples this arm actually compared. **Zero means
    ///     the arm did not run**, whatever its other numbers say.
    ///   - violations: how many of them disagreed with what the arm asserts.
    ///     Meaningless when `observed` is zero, which is the point.
    public static func conclude(
        observed: Int,
        violations: Int
    ) -> (execution: ProbeOutcome.Execution, finding: ProbeOutcome.Finding?) {
        guard observed > 0 else {
            return (.inconclusive, nil)
        }
        return (.measured, violations == 0 ? .yes : .no)
    }
}
