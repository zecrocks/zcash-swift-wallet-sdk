//
//  ZcashNetwork+BlockSpacing.swift
//  ZcashLightClientKit
//

import Foundation

public extension ZcashNetwork {
    /// The target time between the block at `height` and its parent, in seconds: 75 from Blossom
    /// until NU7 and 25 from NU7 activation (ZIP 208, ZIP 218).
    ///
    /// Use this, rather than a fixed 75 seconds, to convert between block counts and wall-clock
    /// time. A span of blocks that crosses NU7 activation has to be measured per height.
    ///
    /// Stateless, and safe to call before any ``Synchronizer`` exists. Returns `nil` only when the
    /// network's parameters are unavailable: a custom network built with
    /// ``ZcashNetworkBuilder/regtest(activationHeights:)`` is known to the SDK only once an
    /// ``Initializer`` has been created for it.
    func targetBlockSpacing(at height: BlockHeight) -> TimeInterval? {
        ZcashRustBackend.targetBlockSpacing(height: height, networkType: networkType)
    }

    /// The number of blocks after its target height at which a transaction the SDK builds for
    /// `targetHeight` expires when no explicit expiry is requested: 40 from Blossom until NU7, and
    /// 120 from NU7 activation, which keeps the same wall-clock window at the shorter spacing.
    ///
    /// The target height of a transaction is the block after the chain tip it was built against.
    /// Returns `nil` under the same conditions as ``targetBlockSpacing(at:)``.
    func defaultExpiryDelta(atTargetHeight targetHeight: BlockHeight) -> Int? {
        ZcashRustBackend.defaultExpiryDelta(targetHeight: targetHeight, networkType: networkType)
    }
}

extension ZcashNetwork {
    /// The default expiry delta that a transaction expiring at `expiryHeight` was built with. See
    /// ``DefaultExpiryDelta/estimated(forExpiryHeight:deltaAtTargetHeight:)``.
    func estimatedDefaultExpiryDelta(forExpiryHeight expiryHeight: BlockHeight) -> Int {
        DefaultExpiryDelta.estimated(forExpiryHeight: expiryHeight) { defaultExpiryDelta(atTargetHeight: $0) }
    }
}

enum DefaultExpiryDelta {
    /// The largest default expiry delta of any network upgrade (NU7's), used when the network's
    /// parameters are unavailable.
    static let largest = 120

    /// The default expiry delta that a transaction expiring at `expiryHeight` was built with,
    /// given the default in effect at each target height.
    ///
    /// The delta depends on the target height, which is what this is used to recover, so the
    /// answer is the delta that is consistent with its own target height: a target height of
    /// `expiryHeight - delta` whose default is `delta`. A transaction whose expiry is consistent
    /// with no default (it was built with an explicit expiry) gets the larger candidate, so that
    /// a caller rewinding to before its target height errs earlier rather than later.
    static func estimated(
        forExpiryHeight expiryHeight: BlockHeight,
        deltaAtTargetHeight: (BlockHeight) -> Int?
    ) -> Int {
        // The default delta never decreases with height, so the one in effect at the expiry
        // height is the largest that can apply.
        guard let latest = deltaAtTargetHeight(expiryHeight) else {
            return largest
        }

        guard
            let earlier = deltaAtTargetHeight(expiryHeight - latest),
            earlier < latest,
            deltaAtTargetHeight(expiryHeight - earlier) == earlier
        else {
            return latest
        }

        return earlier
    }
}
