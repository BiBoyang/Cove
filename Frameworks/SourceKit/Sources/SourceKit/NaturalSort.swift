import Foundation

/// Numeric-aware "natural" ordering for entry names, so pages and files sort
/// `1, 2, …, 10` instead of the lexicographic `1, 10, 2`.
///
/// The heavy lifting is Foundation's `.numeric` string compare (digit runs
/// compare by value, case-insensitively); a literal tiebreak keeps the order
/// total and deterministic when the numeric comparison ties (e.g. "a01" vs
/// "a1"), which Swift's unstable sort requires. Locale-independent, so the
/// browser listing and CBZ page order agree and reproduce across machines.
public enum NaturalSort {
    /// Three-way natural comparison.
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let result = lhs.compare(rhs, options: [.numeric, .caseInsensitive])
        guard result == .orderedSame else { return result }
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    /// `true` when `lhs` sorts before `rhs`; suitable as a sort predicate.
    public static func areInIncreasingOrder(_ lhs: String, _ rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }
}
