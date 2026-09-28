import Foundation

/// Snaps playback rates to the set a player supports (YouTube's iframe player only honours a few rates).
public struct RateQuantizer: Sendable {
    /// The rates the YouTube iframe player offers.
    public static let youTubeStandardRates: [Double] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    /// Allowed rates, always sorted ascending with duplicates, non-finite and non-positive values removed.
    /// When empty, every method returns its input unchanged.
    public var rates: [Double] {
        didSet { rates = Self.cleaned(rates) }
    }

    public init(rates: [Double] = RateQuantizer.youTubeStandardRates) {
        self.rates = Self.cleaned(rates)
    }

    /// The allowed rate closest to `rate` (exact ties go to the slower rate).
    public func nearest(to rate: Double) -> Double {
        guard let index = nearestIndex(to: rate) else { return rate }
        return rates[index]
    }

    /// The allowed rate inside `range` closest to `rate`. If no allowed rate lies inside `range`, the
    /// allowed rate closest to `rate` clamped into `range`.
    public func nearest(to rate: Double, in range: ClosedRange<Double>) -> Double {
        guard !rates.isEmpty else { return rate }
        let inside = rates.filter { range.contains($0) }
        let clamped = rate.isNaN ? rate : min(max(rate, range.lowerBound), range.upperBound)
        guard !inside.isEmpty else { return nearest(to: clamped) }
        return RateQuantizer(rates: inside).nearest(to: clamped)
    }

    /// Moves `steps` allowed rates up (positive) or down (negative) from the allowed rate nearest to
    /// `current`, stopping at the slowest/fastest rate.
    public func step(from current: Double, by steps: Int) -> Double {
        guard let index = nearestIndex(to: current) else { return current }
        let target = index.addingReportingOverflow(steps)
        let clamped = target.overflow ? (steps > 0 ? rates.count - 1 : 0)
                                      : min(max(target.partialValue, 0), rates.count - 1)
        return rates[clamped]
    }

    /// The largest allowed rate not above `rate`, or the smallest allowed rate if all are above it.
    public func floor(_ rate: Double) -> Double {
        guard let first = rates.first else { return rate }
        return rates.last(where: { $0 <= rate + Self.tolerance }) ?? first
    }

    // MARK: - Private

    private static let tolerance = 1e-9

    private func nearestIndex(to rate: Double) -> Int? {
        guard let first = rates.first, let last = rates.last else { return nil }
        let target = rate.isNaN ? 1.0 : rate
        if target <= first { return 0 }
        if target >= last { return rates.count - 1 }
        var best = 0
        var bestDistance = Double.infinity
        for (i, r) in rates.enumerated() {
            let d = abs(r - target)
            // Strictly closer wins, so on an exact tie the earlier (slower) rate is kept.
            if d < bestDistance - Self.tolerance {
                best = i
                bestDistance = d
            }
        }
        return best
    }

    private static func cleaned(_ rates: [Double]) -> [Double] {
        var result: [Double] = []
        for r in rates.filter({ $0.isFinite && $0 > 0 }).sorted() {
            if let last = result.last, abs(last - r) <= tolerance { continue }
            result.append(r)
        }
        return result
    }
}
