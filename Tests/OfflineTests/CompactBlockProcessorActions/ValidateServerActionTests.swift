//
//  ValidateServerActionTests.swift
//
//
//  Created by Lukáš Korba on 16.05.2023.
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class ValidateServerActionTests: ZcashTestCase {
    var underlyingChainName = ""
    var underlyingNetworkType = NetworkType.testnet
    var underlyingNetwork: ZcashNetwork?
    var underlyingSaplingActivationHeight: BlockHeight?
    var underlyingConsensusBranchID = ""
    var underlyingBlockHeight: UInt64 = 2
    var underlyingLocalBranchID: ConsensusBranchID = -1026109260
    var underlyingIronwoodTree = ""

    override func setUp() {
        super.setUp()

        underlyingChainName = "test"
        underlyingNetworkType = .testnet
        underlyingNetwork = nil
        underlyingSaplingActivationHeight = nil
        underlyingConsensusBranchID = "c2d6d0b4"
        underlyingBlockHeight = 2
        underlyingLocalBranchID = -1026109260
        underlyingIronwoodTree = ""
    }

    func testValidateServerAction_NextAction() async throws {
        let validateServerAction = setupAction()

        do {
            let context = ActionContextMock.default()
            let nextContext = try await validateServerAction.run(with: context) { _ in }

            let acResult = nextContext.checkStateIs(.fetchUTXO)
            XCTAssertTrue(acResult == .true, "Check of state failed with '\(acResult)'")
        } catch {
            XCTFail("testValidateServerAction_NextAction is not expected to fail. \(error)")
        }
    }

    func testValidateServerAction_ChainNameError() async throws {
        underlyingChainName = "invalid"

        let validateServerAction = setupAction()

        do {
            _ = try await validateServerAction.run(with: ActionContextMock()) { _ in }
            XCTFail("testValidateServerAction_ChainNameError is expected to fail.")
        } catch ZcashError.compactBlockProcessorChainName(let chainName) {
            XCTAssertEqual(chainName, "invalid")
        } catch {
            XCTFail("""
            testValidateServerAction_ChainNameError is expected to fail but error \(error) doesn't match \
            ZcashError.compactBlockProcessorChainName
            """)
        }
    }

    func testValidateServerAction_NetworkMatchError() async throws {
        underlyingNetworkType = .mainnet

        let validateServerAction = setupAction()

        do {
            _ = try await validateServerAction.run(with: ActionContextMock()) { _ in }
            XCTFail("testValidateServerAction_NetworkMatchError is expected to fail.")
        } catch let ZcashError.compactBlockProcessorNetworkMismatch(expected, found) {
            XCTAssertEqual(expected, .mainnet)
            XCTAssertEqual(found, .testnet)
        } catch {
            XCTFail("""
            testValidateServerAction_NetworkMatchError is expected to fail but error \(error) doesn't match \
            ZcashError.compactBlockProcessorNetworkMismatch
            """)
        }
    }

    func testValidateServerAction_SaplingActivationError() async throws {
        underlyingSaplingActivationHeight = 1

        let validateServerAction = setupAction()

        do {
            _ = try await validateServerAction.run(with: ActionContextMock()) { _ in }
            XCTFail("testValidateServerAction_SaplingActivationError is expected to fail.")
        } catch let ZcashError.compactBlockProcessorSaplingActivationMismatch(expected, found) {
            XCTAssertEqual(expected, 280_000)
            XCTAssertEqual(found, 1)
        } catch {
            XCTFail("""
            testValidateServerAction_SaplingActivationError is expected to fail but error \(error) doesn't match \
            ZcashError.compactBlockProcessorSaplingActivationMismatch
            """)
        }
    }

    func testValidateServerAction_ConsensusBranchIDError_InvalidRemoteBranch() async throws {
        underlyingConsensusBranchID = "1 1"

        let validateServerAction = setupAction()

        do {
            _ = try await validateServerAction.run(with: ActionContextMock()) { _ in }
            XCTFail("testValidateServerAction_ConsensusBranchIDError_InvalidRemoteBranch is expected to fail.")
        } catch ZcashError.compactBlockProcessorConsensusBranchID {
        } catch {
            XCTFail("""
            testValidateServerAction_ConsensusBranchIDError_InvalidRemoteBranch is expected to fail but error \(error) doesn't match \
            ZcashError.compactBlockProcessorConsensusBranchID
            """)
        }
    }

    func testValidateServerAction_ConsensusBranchIDError_ValidRemoteBranch() async throws {
        underlyingConsensusBranchID = "1"

        let validateServerAction = setupAction()

        do {
            _ = try await validateServerAction.run(with: ActionContextMock()) { _ in }
            XCTFail("testValidateServerAction_ConsensusBranchIDError_ValidRemoteBranch is expected to fail.")
        } catch let ZcashError.compactBlockProcessorWrongConsensusBranchId(expected, found) {
            XCTAssertEqual(expected, -1026109260)
            XCTAssertEqual(found, 1)
        } catch {
            XCTFail("""
            testValidateServerAction_ConsensusBranchIDError_ValidRemoteBranch is expected to fail but error \(error) doesn't match \
            ZcashError.compactBlockProcessorWrongConsensusBranchId
            """)
        }
    }

    func testValidateServerAction_CustomNetworkAcceptsMismatchedChainAndBranch() async throws {
        // A regtest custom network syncing against a modified-mainnet Ironwood backend: the backend
        // reports chainName "main" and a nonstandard branch id, but the Sapling activation matches.
        underlyingNetwork = ZcashNetworkBuilder.regtest(
            activationHeights: NetworkActivationHeights(sapling: 1, nu5: 1, nu6: 1, nu6_3: 5000)
        )
        underlyingChainName = "main"
        underlyingConsensusBranchID = "ffffffff"
        underlyingSaplingActivationHeight = nil

        let validateServerAction = setupAction()

        do {
            let context = ActionContextMock.default()
            let nextContext = try await validateServerAction.run(with: context) { _ in }

            let acResult = nextContext.checkStateIs(.fetchUTXO)
            XCTAssertTrue(acResult == .true, "Custom network should pass server validation, got '\(acResult)'")
        } catch {
            XCTFail("Custom network is not expected to fail server validation. \(error)")
        }
    }

    func testValidateServerAction_CustomNetworkStillChecksSaplingActivation() async throws {
        // Even for a custom network, a wrong Sapling-activation height (e.g. a real mainnet server)
        // must still be rejected.
        underlyingNetwork = ZcashNetworkBuilder.regtest(
            activationHeights: NetworkActivationHeights(sapling: 1, nu6_3: 5000)
        )
        underlyingChainName = "main"
        underlyingConsensusBranchID = "ffffffff"
        underlyingSaplingActivationHeight = 419_200

        let validateServerAction = setupAction()

        do {
            _ = try await validateServerAction.run(with: ActionContextMock()) { _ in }
            XCTFail("Custom network with mismatched Sapling activation is expected to fail.")
        } catch let ZcashError.compactBlockProcessorSaplingActivationMismatch(expected, found) {
            XCTAssertEqual(expected, 1)
            XCTAssertEqual(found, 419_200)
        } catch {
            XCTFail("""
            testValidateServerAction_CustomNetworkStillChecksSaplingActivation is expected to fail but error \(error) doesn't match \
            ZcashError.compactBlockProcessorSaplingActivationMismatch
            """)
        }
    }

    // MARK: - Ironwood support probe

    /// Testnet NU6.3 (Ironwood) activation height, from `zcash_protocol`.
    private let testnetNU63Height: UInt64 = 4_134_000
    /// Testnet NU7 activation height, from `zcash_protocol`.
    private let testnetNU7Height: UInt64 = 4_465_026

    func testRequiresIronwoodSupport_FromNU63ActivationOnward() {
        let testnet = ZcashNetworkBuilder.network(for: .testnet)

        XCTAssertFalse(
            ValidateServerAction.requiresIronwoodSupport(serverTipHeight: BlockHeight(testnetNU63Height) - 1, network: testnet)
        )
        XCTAssertTrue(
            ValidateServerAction.requiresIronwoodSupport(serverTipHeight: BlockHeight(testnetNU63Height), network: testnet)
        )
        XCTAssertTrue(
            ValidateServerAction.requiresIronwoodSupport(serverTipHeight: BlockHeight(testnetNU7Height), network: testnet)
        )
        XCTAssertTrue(
            ValidateServerAction.requiresIronwoodSupport(serverTipHeight: BlockHeight(testnetNU7Height) + 1_000_000, network: testnet)
        )
    }

    func testRequiresIronwoodSupport_FalseForCustomNetwork() {
        let regtest = ZcashNetworkBuilder.regtest(
            activationHeights: NetworkActivationHeights(sapling: 1, nu5: 1, nu6: 1, nu6_3: 1, nu7: 1)
        )

        XCTAssertFalse(ValidateServerAction.requiresIronwoodSupport(serverTipHeight: 1_000, network: regtest))
    }

    func testValidateServerAction_PreNU63ServerIsNotProbedForIronwood() async throws {
        let serviceMock = LightWalletServiceMock()
        let validateServerAction = setupAction(serviceMock: serviceMock)

        _ = try await validateServerAction.run(with: ActionContextMock.default()) { _ in }

        XCTAssertFalse(serviceMock.getTreeStateModeCalled)
    }

    func testValidateServerAction_NU63ServerMissingIronwoodFails() async throws {
        underlyingBlockHeight = testnetNU63Height
        underlyingLocalBranchID = ZcashSDK.nu63ConsensusBranchID
        underlyingConsensusBranchID = "37a5165b"
        underlyingIronwoodTree = ""

        try await assertMissingIronwoodSupport()
    }

    func testValidateServerAction_NU7ServerMissingIronwoodFails() async throws {
        underlyingBlockHeight = testnetNU7Height
        underlyingLocalBranchID = ZcashSDK.nu7ConsensusBranchID
        underlyingConsensusBranchID = "77190ad9"
        underlyingIronwoodTree = ""

        try await assertMissingIronwoodSupport()
    }

    func testValidateServerAction_NU7ServerWithIronwoodPasses() async throws {
        underlyingBlockHeight = testnetNU7Height
        underlyingLocalBranchID = ZcashSDK.nu7ConsensusBranchID
        underlyingConsensusBranchID = "77190ad9"
        underlyingIronwoodTree = "01"

        let serviceMock = LightWalletServiceMock()
        let validateServerAction = setupAction(serviceMock: serviceMock)

        let nextContext = try await validateServerAction.run(with: ActionContextMock.default()) { _ in }

        let acResult = nextContext.checkStateIs(.fetchUTXO)
        XCTAssertTrue(acResult == .true, "Check of state failed with '\(acResult)'")
        XCTAssertEqual(serviceMock.getTreeStateModeReceivedArguments?.id.height, testnetNU7Height)
    }

    private func assertMissingIronwoodSupport(file: StaticString = #filePath, line: UInt = #line) async throws {
        let validateServerAction = setupAction()

        do {
            _ = try await validateServerAction.run(with: ActionContextMock()) { _ in }
            XCTFail("A server without Ironwood support is expected to fail validation.", file: file, line: line)
        } catch ZcashError.compactBlockProcessorServerMissingIronwoodSupport {
        } catch {
            XCTFail(
                "Expected ZcashError.compactBlockProcessorServerMissingIronwoodSupport, got \(error)",
                file: file,
                line: line
            )
        }
    }

    private func setupAction(serviceMock: LightWalletServiceMock = LightWalletServiceMock()) -> ValidateServerAction {
        let network = underlyingNetwork ?? ZcashNetworkBuilder.network(for: underlyingNetworkType)
        let config: CompactBlockProcessor.Configuration = .standard(
            for: network, walletBirthday: 0
        )

        let rustBackendMock = ZcashRustBackendWeldingMock()
        let expectedHeight = Int32(underlyingBlockHeight)
        let localBranchID = underlyingLocalBranchID
        rustBackendMock.consensusBranchIdForHeightClosure = { height in
            XCTAssertEqual(height, expectedHeight, "")
            return localBranchID
        }

        let lightWalletdInfoMock = LightWalletdInfoMock()
        lightWalletdInfoMock.underlyingConsensusBranchID = underlyingConsensusBranchID
        lightWalletdInfoMock.underlyingSaplingActivationHeight = UInt64(underlyingSaplingActivationHeight ?? config.saplingActivation)
        lightWalletdInfoMock.underlyingBlockHeight = underlyingBlockHeight
        lightWalletdInfoMock.underlyingChainName = underlyingChainName

        serviceMock.getInfoModeReturnValue = lightWalletdInfoMock
        var treeState = TreeState()
        treeState.ironwoodTree = underlyingIronwoodTree
        serviceMock.getTreeStateModeReturnValue = treeState

        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in rustBackendMock }
        mockContainer.mock(type: LightWalletService.self, isSingleton: true) { _ in serviceMock }
        mockContainer.mock(type: SDKFlags.self, isSingleton: true) { _ in SDKFlags(torEnabled: false, exchangeRateEnabled: false) }

        return ValidateServerAction(
            container: mockContainer,
            configProvider: CompactBlockProcessor.ConfigProvider(config: config)
        )
    }
}
