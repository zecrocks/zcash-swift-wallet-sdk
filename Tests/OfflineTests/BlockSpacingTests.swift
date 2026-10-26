//
//  BlockSpacingTests.swift
//  OfflineTests
//
//  The per-height target block spacing and default expiry delta that NU7 changes (75 s to 25 s,
//  and 40 to 120 blocks), and the SDK values derived from them.
//

import XCTest
@testable import ZcashLightClientKit

final class BlockSpacingTests: XCTestCase {
    /// NU7 activation heights, from `zcash_protocol`.
    private let mainnetNU7: BlockHeight = 3_543_405
    private let testnetNU7: BlockHeight = 4_465_026

    // MARK: - ZcashNetwork.targetBlockSpacing(at:)

    func testTargetBlockSpacingDropsAtNU7Activation() {
        let mainnet = ZcashNetworkBuilder.network(for: .mainnet)
        let testnet = ZcashNetworkBuilder.network(for: .testnet)

        XCTAssertEqual(mainnet.targetBlockSpacing(at: mainnetNU7 - 1), 75)
        XCTAssertEqual(mainnet.targetBlockSpacing(at: mainnetNU7), 25)
        XCTAssertEqual(testnet.targetBlockSpacing(at: testnetNU7 - 1), 75)
        XCTAssertEqual(testnet.targetBlockSpacing(at: testnetNU7), 25)
    }

    // MARK: - ZcashNetwork.defaultExpiryDelta(atTargetHeight:)

    func testDefaultExpiryDeltaRisesAtNU7Activation() {
        let mainnet = ZcashNetworkBuilder.network(for: .mainnet)
        let testnet = ZcashNetworkBuilder.network(for: .testnet)

        XCTAssertEqual(mainnet.defaultExpiryDelta(atTargetHeight: mainnetNU7 - 1), 40)
        XCTAssertEqual(mainnet.defaultExpiryDelta(atTargetHeight: mainnetNU7), 120)
        XCTAssertEqual(testnet.defaultExpiryDelta(atTargetHeight: testnetNU7 - 1), 40)
        XCTAssertEqual(testnet.defaultExpiryDelta(atTargetHeight: testnetNU7), 120)
    }

    // MARK: - Recovering the delta from an expiry height

    func testEstimatedExpiryDeltaBeforeNU7() {
        let mainnet = ZcashNetworkBuilder.network(for: .mainnet)

        // Built for the last pre-NU7 block: expires 40 blocks later, after activation.
        XCTAssertEqual(mainnet.estimatedDefaultExpiryDelta(forExpiryHeight: mainnetNU7 - 1 + 40), 40)
        XCTAssertEqual(mainnet.estimatedDefaultExpiryDelta(forExpiryHeight: mainnetNU7 - 1_000), 40)
    }

    func testEstimatedExpiryDeltaAfterNU7() {
        let mainnet = ZcashNetworkBuilder.network(for: .mainnet)

        XCTAssertEqual(mainnet.estimatedDefaultExpiryDelta(forExpiryHeight: mainnetNU7 + 120), 120)
        XCTAssertEqual(mainnet.estimatedDefaultExpiryDelta(forExpiryHeight: mainnetNU7 + 10_000), 120)
    }

    /// An expiry that no default produces (an explicit expiry) takes the larger delta, so a rewind
    /// to before the transaction's target height errs earlier.
    func testEstimatedExpiryDeltaWithNoConsistentDefaultIsTheLarger() {
        let delta: (BlockHeight) -> Int? = { $0 >= 1_000 ? 120 : 40 }

        XCTAssertEqual(DefaultExpiryDelta.estimated(forExpiryHeight: 1_039, deltaAtTargetHeight: delta), 40)
        XCTAssertEqual(DefaultExpiryDelta.estimated(forExpiryHeight: 1_080, deltaAtTargetHeight: delta), 120)
        XCTAssertEqual(DefaultExpiryDelta.estimated(forExpiryHeight: 1_120, deltaAtTargetHeight: delta), 120)
        XCTAssertEqual(
            DefaultExpiryDelta.estimated(forExpiryHeight: 1_120) { _ in nil },
            DefaultExpiryDelta.largest
        )
    }

    // MARK: - Poll interval

    func testPollIntervalIsHalfTheSpacingCappedAtTheDefault() {
        XCTAssertEqual(ZcashSDK.pollInterval(targetBlockSpacing: 75), ZcashSDK.defaultPollInterval)
        XCTAssertEqual(ZcashSDK.pollInterval(targetBlockSpacing: 25), 12.5)
        XCTAssertEqual(ZcashSDK.pollInterval(targetBlockSpacing: nil), ZcashSDK.defaultPollInterval)
    }
}
