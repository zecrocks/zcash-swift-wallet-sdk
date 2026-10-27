//
//  ChainTipEstimator.swift
//  ZcashLightClientKit
//

import Foundation

/// A pure, measured-block-rate chain-tip estimator: projects a wall-clock ESTIMATED chain tip
/// from the most recently scanned blocks' `(height, header time)` samples
/// (`ZcashRustBackendWelding.migrationBlockRateSamples(window:)`).
///
/// The projection feeds the migration delivery lane's `estimatedTip` inputs
/// (`migrationHasOverdueTransfers(for:estimatedTip:)` / `migrationAdvanceStep(for:estimatedTip:)`)
/// AND — since upstream #2927 — the overdue re-spread inside `advance_migration`, which is
/// **judged and sized at the estimate and PERSISTED**: an over-estimate is no longer "at worst an
/// early due answer"; it writes phantom deferral into the stored schedule. Accuracy here is
/// load-bearing. (Field incident, 2026-08-08 `data37`: a burst-skewed measurement compounded by
/// two wake-time re-spreads parked a live testnet run ~2,690 blocks — half a day — past the real
/// chain. The engine-side hardening — bounding what a caller estimate may size — is tracked
/// separately; this type's job is to not hand it poison in the first place.)
///
/// THE RATE IS A SPAN, NOT A DELTA MEAN. `secondsPerBlock()` divides the window's total
/// header-time span by its total height span. The previous implementation averaged consecutive
/// per-delta spacings, each clamped to [``minSecondsPerBlock``, ``maxSecondsPerBlock``] — a
/// statistic that is biased LOW on bimodal spacing: testnet's min-difficulty rule yields bursts
/// (seconds apart, clamped UP to 5) punctuated by gaps (clamped DOWN to 150), and the bursts
/// dominate by count. A span is immune: a gap and the burst it triggers average out inside it. A
/// span also needs no adjacency assumption — non-consecutive sample heights divide by the true
/// height distance instead of counting rows.
///
/// THE WINDOW IS ABSENCE-SCALED. The rate is extrapolated across app-dead gaps measured in hours,
/// so the sample span must cover hours: ``sampleWindow`` is 1000 blocks (~21 h at the pre-NU7 target spacing, ~7 h at the post-NU7 one;
/// ~6–9 h on a burst-fast testnet). The prior 100-block window (~2 h at target, and as little as
/// ~30 min on a fast chain) measured whatever regime the chain happened to be in right before
/// sleep and projected it across the whole night — in the field incident the pre-sleep half hour
/// ran ~20 s/block while the night averaged 31 s/block, an error the span statistic alone cannot
/// fix.
///
/// Constants heritage: the clamps and fallback still mirror the Android SDK's estimator; the
/// method (span vs clamped-delta mean) and the window (1000 vs 100) deliberately diverge — the
/// Kotlin estimator retains the biased statistic and the short window and needs the same fix.
struct ChainTipEstimator {
    /// How many of the latest samples participate, at most. Widened from the Android-parity 100:
    /// the rate extrapolates across absence-scale gaps, so the sample span must cover
    /// absence-scale regime changes (see the type doc).
    static let sampleWindow = 1000
    /// The lower sanity clamp on the final span rate, in seconds (Android parity: 5).
    static let minSecondsPerBlock: Double = 5
    /// The upper sanity clamp on the final span rate, in seconds (Android parity: 150).
    static let maxSecondsPerBlock: Double = 150
    /// The seconds-per-block assumed when no rate can be measured and the network's target
    /// spacing is unknown (Android parity: 75 — the target block spacing before NU7).
    static let fallbackSecondsPerBlock: Double = 75
    /// A height past every scheduled network upgrade, at which ``targetSpacing`` reports the
    /// shortest spacing the network will have when there is no sample to take a height from.
    static let farFutureHeight = BlockHeight(UInt32.max)

    /// The `(height, header time)` samples, ascending by height (the order the welding returns).
    private let samples: [MigrationBlockRateSample]
    /// The network's target spacing, in seconds, of the block at a height (75 s before NU7, 25 s
    /// from NU7 activation), or `nil` when the network's parameters are unavailable.
    private let targetSpacing: (BlockHeight) -> Double?

    /// Creates an estimator over `samples` (ascending by height; may be empty) that falls back to
    /// `targetSpacing` when no rate can be measured.
    init(samples: [MigrationBlockRateSample], targetSpacing: @escaping (BlockHeight) -> Double? = { _ in nil }) {
        self.samples = samples
        self.targetSpacing = targetSpacing
    }

    /// The seconds-per-block assumed when no rate can be measured: the network's target spacing
    /// of the block after the latest sample, since the measurement would otherwise have covered
    /// the blocks that follow it. With no sample at all it is the spacing at
    /// ``farFutureHeight``, the shortest the network will have (25 s once NU7 is scheduled), so
    /// that a timer derived from it errs early rather than late. ``fallbackSecondsPerBlock`` when
    /// the network's spacing is unknown.
    func targetFallbackSecondsPerBlock() -> Double {
        let height = samples.last.map { $0.height + 1 } ?? Self.farFutureHeight
        return targetSpacing(height) ?? Self.fallbackSecondsPerBlock
    }

    /// The measured seconds-per-block: the SPAN rate over up to the last ``sampleWindow``
    /// samples — total header-time span divided by total height span — clamped once to
    /// [``minSecondsPerBlock``, ``maxSecondsPerBlock``].
    ///
    /// ``targetFallbackSecondsPerBlock()`` when no rate can be measured: fewer than two samples, a window
    /// spanning no height, or header times that do not advance across the window (header times
    /// are miner-supplied and may locally regress; a whole window that fails to advance is a
    /// broken measurement, not a fast chain).
    func secondsPerBlock() -> Double {
        let window = samples.suffix(Self.sampleWindow)
        guard window.count >= 2, let first = window.first, let last = window.last else {
            return targetFallbackSecondsPerBlock()
        }

        let heightSpan = Double(last.height - first.height)
        let timeSpan = Double(last.unixTime - first.unixTime)
        guard heightSpan > 0, timeSpan > 0 else {
            return targetFallbackSecondsPerBlock()
        }

        return min(max(timeSpan / heightSpan, Self.minSecondsPerBlock), Self.maxSecondsPerBlock)
    }

    /// The estimated chain tip at `now`: the latest sample's height plus the whole blocks that
    /// fit into the wall-clock time elapsed since its header time at ``secondsPerBlock()``,
    /// never below the latest sample's height (a header time in the future adds zero). `nil`
    /// when there are no samples at all — the wallet has never scanned, so there is nothing to
    /// project from.
    func estimatedTip(now: Date) -> BlockHeight? {
        guard let latest = samples.last else {
            return nil
        }

        let elapsed = now.timeIntervalSince1970 - Double(latest.unixTime)
        let advancedBlocks = max(0, Int(floor(elapsed / secondsPerBlock())))
        return latest.height + advancedBlocks
    }
}

/// The ONE shared read-and-project composition behind every migration tip-estimate consumer: read
/// the welding's block-rate samples over ``ChainTipEstimator/sampleWindow`` and run
/// ``ChainTipEstimator`` at an INJECTED instant. Both `OrchardMigration` and
/// `OrchardMigrationHost` — the gate/delivery paths and the public
/// `estimatedMigrationChainTip()`/`estimatedMigrationSecondsPerBlock()` members — go through
/// here, so the window constant, the estimator wiring, and the clock injection cannot drift apart
/// between call sites.
enum MigrationTipEstimation {
    /// The network's target spacing, in seconds, of the block at a height, or `nil` when it is
    /// unknown. See ``ChainTipEstimator/targetFallbackSecondsPerBlock()``.
    typealias TargetSpacing = @Sendable (BlockHeight) -> Double?

    /// The target spacing of `networkType`'s blocks, as the Rust core defines it per height.
    static func targetSpacing(for networkType: NetworkType) -> TargetSpacing {
        { ZcashRustBackend.targetBlockSpacing(height: $0, networkType: networkType) }
    }

    /// A target spacing that is never known, so the estimator falls back to
    /// ``ChainTipEstimator/fallbackSecondsPerBlock``. The default of the injecting initializers.
    static let unknownTargetSpacing: TargetSpacing = { _ in nil }

    /// One projection over one samples read: the estimated tip (`nil` with no samples at all —
    /// the wallet has never scanned) and the measured seconds-per-block (the estimator's
    /// fallback when no rate can be measured).
    struct Projection {
        /// The wall-clock estimated chain tip, or `nil` when there are no samples to project from.
        let estimatedTip: BlockHeight?
        /// The measured seconds-per-block (see ``ChainTipEstimator/secondsPerBlock()``).
        let secondsPerBlock: Double
    }

    /// Reads the samples and projects at `now`. THROWING: a sample-read failure propagates — this
    /// is the core the public estimated members surface errors from; gate paths use
    /// ``gatingEstimatedTip(welding:targetSpacing:now:)`` instead, which degrades.
    static func project(
        welding: ZcashRustBackendWelding,
        targetSpacing: @escaping TargetSpacing,
        now: Date
    ) async throws -> Projection {
        let estimator = ChainTipEstimator(
            samples: try await welding.migrationBlockRateSamples(window: UInt32(ChainTipEstimator.sampleWindow)),
            targetSpacing: targetSpacing
        )
        return Projection(estimatedTip: estimator.estimatedTip(now: now), secondsPerBlock: estimator.secondsPerBlock())
    }

    /// The estimated tip for gate/delivery due-ness checks: ``project(welding:targetSpacing:now:)``'s tip,
    /// degraded to `nil` (scanned-tip behavior) on ANY failure — sample read errors included — so
    /// a read failure can only ever fall back to, never block or crash, the paths that consult
    /// it. NOTE: since upstream #2927 the non-nil estimate is not merely accelerating — it sizes
    /// the persisted overdue re-spread (see the type doc above).
    static func gatingEstimatedTip(
        welding: ZcashRustBackendWelding,
        targetSpacing: @escaping TargetSpacing,
        now: Date
    ) async -> BlockHeight? {
        (try? await project(welding: welding, targetSpacing: targetSpacing, now: now))?.estimatedTip
    }
}
