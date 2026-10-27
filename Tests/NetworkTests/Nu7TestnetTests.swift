//
//  Nu7TestnetTests.swift
//  ZcashLightClientKit
//

import CommonCrypto
import Foundation
import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

/// Opt-in NU7 verification against the live Zcash testnet through `testnet.zec.rocks:443`.
///
/// Every test is skipped unless the environment variable `NU7_TESTNET=1` is set, so the regular
/// test runs (which compile but do not select this target) are unaffected. The
/// `testnet-verification.yml` workflow runs it on macOS.
///
/// Environment:
/// - `NU7_TESTNET_SEED`: a BIP 39 mnemonic for the wallet. When it is absent a random seed is used,
///   which is enough to verify syncing but can never hold funds, so the spend tests skip.
/// - `NU7_TESTNET_SYNC_TIMEOUT_MINUTES` (default 60) and `NU7_TESTNET_MINE_TIMEOUT_MINUTES`
///   (default 10).
///
/// Every line this suite prints starts with `NU7TEST`, including the wallet's addresses, so a
/// person can fund the wallet from a CI log and rerun to exercise the spend tests. The seed itself
/// is never printed.
///
/// The test methods are numbered because XCTest runs them in name order and the later ones reuse
/// the wallet the sync test restored.
final class Nu7TestnetTests: XCTestCase {
    static let nu7Activation: BlockHeight = 4_465_026
    // Before the activation height, so the restore scans across the upgrade boundary.
    static let birthday: BlockHeight = 4_460_000
    static let syncMargin: BlockHeight = 10
    static let minSpendable = Zatoshi(50_000)
    static let sendAmount = Zatoshi(10_000)
    static let shieldingThreshold = Zatoshi(10_000)
    // The builder targets the block after the chain tip and NU7 expires transactions 120 blocks
    // after that, so expiry lands at tip + 121; the slack absorbs a block mined mid-test.
    static let expiryDeltaRange: ClosedRange<BlockHeight> = 118...122
    static let pollInterval: UInt64 = 5_000_000_000

    static let endpoint = LightWalletEndpoint(
        address: "testnet.zec.rocks",
        port: 443,
        secure: true,
        singleCallTimeoutInMillis: 30_000,
        streamingCallTimeoutInMillis: 600_000
    )
    static let network = ZcashNetworkBuilder.network(for: .testnet)

    static var isEnabled: Bool { env("NU7_TESTNET") == "1" }
    static var syncTimeoutMinutes: Double { Double(env("NU7_TESTNET_SYNC_TIMEOUT_MINUTES") ?? "") ?? 60 }
    static var mineTimeoutMinutes: Double { Double(env("NU7_TESTNET_MINE_TIMEOUT_MINUTES") ?? "") ?? 10 }

    // The wallet is shared by the tests in this class and torn down once in `tearDown()`.
    private static var wallet: Wallet?

    struct TestFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    struct Wallet {
        let synchronizer: SDKSynchronizer
        let seed: [UInt8]
        let isEphemeral: Bool
        let account: AccountUUID
        let directory: URL
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(Self.isEnabled, "NU7 testnet verification is opt-in: set NU7_TESTNET=1")
    }

    override class func tearDown() {
        if let wallet {
            wallet.synchronizer.stop()
            // Give the stop a moment to release the databases before removing them.
            Thread.sleep(forTimeInterval: 2)
            try? FileManager.default.removeItem(at: wallet.directory)
        }
        wallet = nil
        super.tearDown()
    }

    // MARK: - a. The server and the SDK agree on NU7

    func test1_serverIsOnNu7() async throws {
        let service = LightWalletServiceFactory(endpoint: Self.endpoint).make()
        let info = try await service.getInfo(mode: .direct)
        let serverTip = BlockHeight(info.blockHeight)
        let serverBranch = ConsensusBranchID.fromString(info.consensusBranchID)
        Self.log(
            "server \(Self.endpoint.host):\(Self.endpoint.port) chain=\(info.chainName) tip=\(serverTip) "
            + "estimatedHeight=\(info.estimatedHeight) branchId=0x\(info.consensusBranchID) "
            + "lightwalletd=\(info.version) \(info.vendor)"
        )

        XCTAssertEqual(info.chainName, "test")
        XCTAssertGreaterThan(serverTip, Self.nu7Activation, "server tip must be past NU7 activation")
        XCTAssertEqual(serverBranch, ZcashSDK.nu7ConsensusBranchID, "server must report the NU7 branch id")

        // The SDK's own consensus rules, independent of any server.
        let backend = ZcashRustBackend.makeForTests(fsBlockDbRoot: Self.scratchDirectory("branch"), networkType: .testnet)
        let beforeActivation = try backend.consensusBranchIdFor(height: Int32(Self.nu7Activation - 1))
        let atActivation = try backend.consensusBranchIdFor(height: Int32(Self.nu7Activation))
        let atTip = try backend.consensusBranchIdFor(height: Int32(serverTip))
        Self.log(
            "sdk branchId at \(Self.nu7Activation - 1)=0x\(beforeActivation.toString()) "
            + "at \(Self.nu7Activation)=0x\(atActivation.toString()) at tip \(serverTip)=0x\(atTip.toString())"
        )
        XCTAssertEqual(beforeActivation, ZcashSDK.nu63ConsensusBranchID, "the block before activation must be NU6.3")
        XCTAssertEqual(atActivation, ZcashSDK.nu7ConsensusBranchID, "the activation block must be NU7")
        XCTAssertEqual(atTip, ZcashSDK.nu7ConsensusBranchID, "the tip must be NU7")

        // The exact check the sync pipeline runs on every cycle, against the live server.
        let container = DIContainer()
        container.register(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in backend }
        container.register(type: LightWalletService.self, isSingleton: true) { _ in service }
        container.register(type: SDKFlags.self, isSingleton: true) { _ in SDKFlags(torEnabled: false, exchangeRateEnabled: false) }
        let action = ValidateServerAction(
            container: container,
            configProvider: CompactBlockProcessor.ConfigProvider(config: .standard(for: Self.network, walletBirthday: Self.birthday))
        )
        let context = ActionContextImpl(state: .validateServer)
        do {
            _ = try await action.run(with: context, didUpdate: { _ in })
        } catch {
            XCTFail("ValidateServerAction rejected the server: \(Self.describe(error))")
            return
        }
        let nextState = await context.state
        Self.log("ValidateServerAction passed, next state=\(nextState)")
        XCTAssertEqual(nextState, .fetchUTXO)
    }

    // MARK: - b. A restore from before activation syncs across it

    func test2_syncAcrossNu7Activation() async throws {
        let started = Date()
        let wallet = try await Self.sharedWallet()
        try await Self.logAddresses(wallet)

        let state = try await Self.syncToTip(wallet.synchronizer)
        let elapsed = Date().timeIntervalSince(started)

        let service = LightWalletServiceFactory(endpoint: Self.endpoint).make()
        let serverTip = try await service.latestBlockHeight(mode: .direct)
        Self.log(
            "synced in \(Int(elapsed))s: fullyScannedHeight=\(state.fullyScannedHeight) "
            + "latestBlockHeight=\(state.latestBlockHeight) serverTip=\(serverTip)"
        )
        XCTAssertGreaterThanOrEqual(state.fullyScannedHeight, serverTip - Self.syncMargin, "scan must reach the server tip")
        XCTAssertGreaterThan(state.fullyScannedHeight, Self.nu7Activation, "scan must cross NU7 activation")

        // The synchronizer's own server evaluation, which rules out servers whose branch id
        // differs from the SDK's at the server's tip.
        let evaluated = await wallet.synchronizer.evaluateBestOf(
            endpoints: [Self.endpoint],
            fetchThresholdSeconds: 120,
            nBlocksToFetch: 100,
            kServers: 1,
            network: .testnet
        )
        Self.log("evaluateBestOf: \(evaluated.map { "\($0.host):\($0.port)" })")
        XCTAssertEqual(evaluated, [Self.endpoint], "the synchronizer must accept the NU7 server")

        let balances = try await wallet.synchronizer.getAccountsBalances()
        Self.log("balance after sync: \(Self.describe(balances[wallet.account]))")
        try await Self.logAddresses(wallet)
    }

    // MARK: - c. A shielded send under NU7

    func test3_sendUnderNu7() async throws {
        let wallet = try await Self.fundableWallet()
        _ = try await Self.syncToTip(wallet.synchronizer)

        let balance = try await wallet.synchronizer.getAccountsBalances()[wallet.account]
        let spendable = balance?.shieldedSpendableValue ?? .zero
        Self.log("spendable shielded balance: \(spendable.amount) zats (\(Self.describe(balance)))")
        guard spendable >= Self.minSpendable else {
            try await Self.logAddresses(wallet)
            throw XCTSkip(
                "needs \(Self.minSpendable.amount) spendable shielded zats, has \(spendable.amount); "
                + "fund the NU7TEST addresses and rerun"
            )
        }

        let address = try await wallet.synchronizer.getUnifiedAddress(accountUUID: wallet.account)
        let recipient = try Recipient(address.stringEncoded, network: .testnet)
        let creationTip = try await wallet.synchronizer.latestHeight()
        let proposal = try await wallet.synchronizer.proposeTransfer(
            accountUUID: wallet.account,
            recipient: recipient,
            amount: Self.sendAmount,
            memo: try Memo(string: "NU7 testnet self-transfer")
        )
        Self.log(
            "transfer proposal: transactions=\(proposal.transactionCount()) "
            + "fee=\(proposal.totalFeeRequired().amount) creationTip=\(creationTip)"
        )

        let mined = try await Self.createAndAwaitMined(wallet, proposal: proposal)
        let minedHeight = try XCTUnwrap(mined.minedHeight)
        let expiryHeight = try XCTUnwrap(mined.expiryHeight)
        Self.log(
            "send mined: minedHeight=\(minedHeight) expiryHeight=\(expiryHeight) creationTip=\(creationTip) "
            + "expiry-creationTip=\(expiryHeight - creationTip) fee=\(mined.fee?.amount ?? -1)"
        )
        XCTAssertGreaterThan(minedHeight, Self.nu7Activation, "the send must be mined under NU7")
        XCTAssertTrue(
            Self.expiryDeltaRange.contains(expiryHeight - creationTip),
            "expiry delta \(expiryHeight - creationTip) must be in \(Self.expiryDeltaRange) (NU7 expects 121)"
        )
    }

    // MARK: - d. Shielding under NU7

    func test4_shieldUnderNu7() async throws {
        let wallet = try await Self.fundableWallet()
        _ = try await Self.syncToTip(wallet.synchronizer)

        let balance = try await wallet.synchronizer.getAccountsBalances()[wallet.account]
        let transparent = balance?.unshielded ?? .zero
        Self.log("transparent balance: \(transparent.amount) zats")
        guard transparent > .zero else {
            try await Self.logAddresses(wallet)
            throw XCTSkip("no transparent funds to shield; send some to the NU7TEST transparent address and rerun")
        }

        let creationTip = try await wallet.synchronizer.latestHeight()
        let proposal = try await wallet.synchronizer.proposeShielding(
            accountUUID: wallet.account,
            shieldingThreshold: Self.shieldingThreshold,
            memo: try Memo(string: "NU7 testnet shielding"),
            transparentReceiver: nil
        )
        guard let proposal else {
            throw XCTSkip("transparent balance \(transparent.amount) is below the shielding threshold \(Self.shieldingThreshold.amount)")
        }
        Self.log(
            "shielding proposal: transactions=\(proposal.transactionCount()) "
            + "fee=\(proposal.totalFeeRequired().amount) creationTip=\(creationTip)"
        )

        let mined = try await Self.createAndAwaitMined(wallet, proposal: proposal)
        let minedHeight = try XCTUnwrap(mined.minedHeight)
        let expiryHeight = try XCTUnwrap(mined.expiryHeight)
        Self.log(
            "shield mined: minedHeight=\(minedHeight) expiryHeight=\(expiryHeight) "
            + "expiry-creationTip=\(expiryHeight - creationTip) isShielding=\(mined.isShielding)"
        )
        XCTAssertGreaterThan(minedHeight, Self.nu7Activation, "the shielding must be mined under NU7")
        XCTAssertTrue(mined.isShielding)
        XCTAssertTrue(
            Self.expiryDeltaRange.contains(expiryHeight - creationTip),
            "expiry delta \(expiryHeight - creationTip) must be in \(Self.expiryDeltaRange) (NU7 expects 121)"
        )
    }
}

// MARK: - Helpers

private extension Nu7TestnetTests {
    static func env(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            return nil
        }
        return value
    }

    static func log(_ message: String) {
        print("NU7TEST \(message)")
        // XCTest buffers stdout; flushing keeps the CI log in step with the run.
        fflush(stdout)
    }

    static func scratchDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nu7-testnet-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Describes an error by its SDK code and generic message only. Associated values can carry
    /// caller input, so the reflected description is never printed.
    static func describe(_ error: Error) -> String {
        if let zcashError = error as? ZcashError {
            return "\(zcashError.code.rawValue): \(zcashError.message)"
        }
        return "\(type(of: error)): \(error.localizedDescription)"
    }

    static func describe(_ balance: AccountBalance?) -> String {
        guard let balance else { return "no balance" }
        func pool(_ value: PoolBalance) -> String { "\(value.spendableValue.amount)/\(value.total().amount)" }
        return "sapling=\(pool(balance.saplingBalance)) orchard=\(pool(balance.orchardBalance)) "
            + "ironwood=\(pool(balance.ironwoodBalance)) transparent=\(balance.unshielded.amount) (spendable/total zats)"
    }

    /// The BIP 39 seed for `mnemonic` with an empty passphrase: PBKDF2-HMAC-SHA512 over the NFKD
    /// mnemonic, salted with "mnemonic", 2048 rounds. The SDK has no mnemonic support of its own, and
    /// only a test wallet's seed passes through here.
    static func bip39Seed(mnemonic: String) throws -> [UInt8] {
        let words = mnemonic.split(whereSeparator: { $0.isWhitespace })
        guard [12, 15, 18, 21, 24].contains(words.count) else {
            throw TestFailure(message: "NU7_TESTNET_SEED must be a BIP 39 mnemonic (it has \(words.count) words)")
        }
        let password = Array(words.joined(separator: " ").decomposedStringWithCompatibilityMapping.utf8)
        let salt = Array("mnemonic".decomposedStringWithCompatibilityMapping.utf8)
        let seedLength = 64
        var seed = [UInt8](repeating: 0, count: seedLength)
        let status = password.withUnsafeBufferPointer { passwordBuffer in
            passwordBuffer.withMemoryRebound(to: Int8.self) { passwordChars in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordChars.baseAddress,
                    password.count,
                    salt,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                    2048,
                    &seed,
                    seedLength
                )
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else {
            throw TestFailure(message: "PBKDF2 failed with status \(status)")
        }
        return seed
    }

    /// The wallet restored from `birthday`, created on first use and shared by the tests.
    static func sharedWallet() async throws -> Wallet {
        if let wallet {
            return wallet
        }

        let seed: [UInt8]
        let isEphemeral: Bool
        if let mnemonic = env("NU7_TESTNET_SEED") {
            seed = try bip39Seed(mnemonic: mnemonic)
            isEphemeral = false
        } else {
            seed = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
            isEphemeral = true
        }

        let directory = scratchDirectory("wallet")
        let initializer = Initializer(
            cacheDbURL: nil,
            fsBlockDbRoot: directory.appendingPathComponent("fs_cache", isDirectory: true),
            generalStorageURL: directory.appendingPathComponent("general", isDirectory: true),
            dataDbURL: directory.appendingPathComponent("data.db"),
            torDirURL: directory.appendingPathComponent("tor", isDirectory: true),
            endpoint: endpoint,
            network: network,
            spendParamsURL: directory.appendingPathComponent("sapling-spend.params"),
            outputParamsURL: directory.appendingPathComponent("sapling-output.params"),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests,
            alias: .custom("nu7test"),
            loggingPolicy: .custom(WarningLogger()),
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )
        let synchronizer = SDKSynchronizer(initializer: initializer)

        let result = try await synchronizer.prepare(with: seed, walletBirthday: birthday, name: "NU7 test", keySource: nil)
        guard case .success = result else {
            throw TestFailure(message: "prepare did not succeed: \(result)")
        }
        let accounts = try await synchronizer.listAccounts()
        let account = try XCTUnwrap(accounts.first, "restore must create an account")
        log(
            "restored \(isEphemeral ? "an ephemeral random-seed" : "the NU7_TESTNET_SEED") wallet: "
            + "requested birthday=\(birthday) checkpoint birthday=\(initializer.walletBirthday)"
        )

        let created = Wallet(synchronizer: synchronizer, seed: seed, isEphemeral: isEphemeral, account: account.id, directory: directory)
        wallet = created
        try await synchronizer.start(retry: true)
        return created
    }

    /// The shared wallet, or a skip when it was made from a random seed, which cannot have funds.
    static func fundableWallet() async throws -> Wallet {
        guard env("NU7_TESTNET_SEED") != nil else {
            throw XCTSkip("NU7_TESTNET_SEED is not set, so the wallet has no funds to spend")
        }
        return try await sharedWallet()
    }

    static func logAddresses(_ wallet: Wallet) async throws {
        let unified = try await wallet.synchronizer.getUnifiedAddress(accountUUID: wallet.account)
        let transparent = try await wallet.synchronizer.getTransparentAddress(accountUUID: wallet.account)
        log("==================== FUND THIS TESTNET WALLET ====================")
        if wallet.isEphemeral {
            log("(random seed for this run only: set the NU7_TESTNET_SEED secret to keep a fundable wallet)")
        }
        log("unified address:     \(unified.stringEncoded)")
        log("transparent address: \(transparent.stringEncoded)")
        log("==================================================================")
    }

    /// Waits until the synchronizer reports it is synced with its fully scanned height at the chain
    /// tip, and returns that state.
    static func syncToTip(_ synchronizer: SDKSynchronizer) async throws -> SynchronizerState {
        let deadline = Date().addingTimeInterval(syncTimeoutMinutes * 60)
        var polls = 0
        var lastError: String?
        // The synchronizer retries failed syncs indefinitely, so a deterministic failure would
        // otherwise only surface at the timeout. Fail once errors recur with no scan progress.
        let stallLimit: TimeInterval = 15 * 60
        var lastProgress: Float = -1
        var lastProgressAt = Date()
        while Date() < deadline {
            let state = synchronizer.latestState
            switch state.syncStatus {
            case let .error(error):
                let description = describe(error)
                if description != lastError {
                    log("sync error (the synchronizer retries): \(description)")
                    lastError = description
                }
            case let .syncing(progress, _) where progress != lastProgress:
                lastProgress = progress
                lastProgressAt = Date()
            default:
                break
            }
            if let lastError, Date().timeIntervalSince(lastProgressAt) > stallLimit {
                throw TestFailure(
                    message: "no sync progress for \(Int(stallLimit / 60)) minutes at "
                    + "fullyScanned=\(state.fullyScannedHeight) progress=\(lastProgress); last error: \(lastError)"
                )
            }
            if polls % 12 == 0 {
                log(
                    "sync status=\(state.internalSyncStatus) fullyScanned=\(state.fullyScannedHeight) "
                    + "latestBlockHeight=\(state.latestBlockHeight)"
                )
            }
            polls += 1
            let atTip = state.latestBlockHeight > 0 && state.fullyScannedHeight >= state.latestBlockHeight - syncMargin
            if state.syncStatus.isSynced && atTip {
                return state
            }
            try await Task.sleep(nanoseconds: pollInterval)
        }
        let state = synchronizer.latestState
        throw TestFailure(
            message: "not synced within \(syncTimeoutMinutes) minutes: status=\(state.internalSyncStatus) "
            + "fullyScanned=\(state.fullyScannedHeight) latestBlockHeight=\(state.latestBlockHeight) "
            + "lastError=\(lastError ?? "none")"
        )
    }

    /// Creates and submits the proposal's transactions, then waits for the last one to be mined.
    static func createAndAwaitMined(_ wallet: Wallet, proposal: Proposal) async throws -> ZcashTransaction.Overview {
        let spendingKey = try DerivationTool(networkType: .testnet)
            .deriveUnifiedSpendingKey(seed: wallet.seed, accountIndex: Zip32AccountIndex(0))

        var txIds: [Data] = []
        for try await result in try await wallet.synchronizer.createProposedTransactions(proposal: proposal, spendingKey: spendingKey) {
            switch result {
            case let .success(txId):
                log("submitted \(txId.toHexStringTxId())")
                txIds.append(txId)
            case let .grpcFailure(txId, error):
                XCTFail("gRPC failure submitting \(txId.toHexStringTxId()): \(describe(error))")
            case let .submitFailure(txId, code, description):
                XCTFail("server rejected \(txId.toHexStringTxId()): code=\(code) \(description)")
            case let .notAttempted(txId):
                XCTFail("submission not attempted for \(txId.toHexStringTxId())")
            }
        }
        XCTAssertEqual(txIds.count, proposal.transactionCount())
        let txId = try XCTUnwrap(txIds.last, "no transaction was submitted")

        let deadline = Date().addingTimeInterval(mineTimeoutMinutes * 60)
        while Date() < deadline {
            let transactions = try await wallet.synchronizer.allTransactions()
            if let mined = transactions.first(where: { $0.rawID == txId && $0.minedHeight != nil }) {
                return mined
            }
            try await Task.sleep(nanoseconds: pollInterval * 2)
        }
        throw TestFailure(message: "\(txId.toHexStringTxId()) was not mined within \(mineTimeoutMinutes) minutes")
    }
}

/// Prints the SDK's warnings and errors to stdout so they appear in the CI log; the per-batch
/// debug and info lines of a long restore would bury the suite's own output.
private struct WarningLogger: Logger {
    func maxLogLevel() -> OSLogger.LogLevel? { .warning }
    func debug(_ message: String, file: StaticString, function: StaticString, line: Int) {}
    func info(_ message: String, file: StaticString, function: StaticString, line: Int) {}
    func event(_ message: String, file: StaticString, function: StaticString, line: Int) {}
    func sync(_ message: String, file: StaticString, function: StaticString, line: Int) {}

    func warn(_ message: String, file: StaticString, function: StaticString, line: Int) {
        emit("WARNING", message, file, line)
    }

    func error(_ message: String, file: StaticString, function: StaticString, line: Int) {
        emit("ERROR", message, file, line)
    }

    private func emit(_ level: String, _ message: String, _ file: StaticString, _ line: Int) {
        let fileName = (String(describing: file) as NSString).lastPathComponent
        print("[\(level)] \(fileName):\(line) \(message)")
        fflush(stdout)
    }
}
