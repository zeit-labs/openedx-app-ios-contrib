//
//  PendingTransactionStore.swift
//  Payment
//
//  Created by Rawan Matar on 15/04/2026.
//

import Foundation
import Core
import OEXFoundation

// MARK: - PendingTransaction model

/// A purchase that has been verified by StoreKit 2 but not yet acknowledged
/// by the Open edX backend. Persisted across process restarts.
public struct PendingTransaction: Codable, Identifiable {

    /// Stable identifier — the App Store transaction ID.
    public var id: UInt64 { transactionID }

    public let transactionID: UInt64
    public let productID: String
    public let courseID: String
    /// The raw JWS string from `VerificationResult<Transaction>.jwsRepresentation`.
    public let jwsRepresentation: String
    public let purchaseDate: Date
    /// ISO-8601 string version of `purchaseDate` (sent to backend).
    public let purchaseDateString: String
    public let bundleID: String

    // MARK: Retry bookkeeping

    /// Number of times this transaction has been submitted to the backend and failed.
    public var failureCount: Int = 0
    /// Timestamp of the last failed attempt (nil if never attempted).
    public var lastAttemptDate: Date?
    /// `true` once we give up and surface a permanent error to the user.
    public var isPermanentlyFailed: Bool = false

    // MARK: Init

    public init(
        transactionID: UInt64,
        productID: String,
        courseID: String,
        jwsRepresentation: String,
        purchaseDate: Date,
        bundleID: String
    ) {
        self.transactionID = transactionID
        self.productID = productID
        self.courseID = courseID
        self.jwsRepresentation = jwsRepresentation
        self.purchaseDate = purchaseDate
        self.purchaseDateString = ISO8601DateFormatter().string(from: purchaseDate)
        self.bundleID = bundleID
    }

    // MARK: Retry delay computation (exponential backoff with jitter)

    /// How long to wait before the next retry attempt.
    ///
    /// | Attempt | Base delay | With ±20% jitter |
    /// |---------|-----------|-----------------|
    /// | 1       | 30 s      | 24 – 36 s       |
    /// | 2       | 60 s      | 48 – 72 s       |
    /// | 3       | 120 s     | 96 – 144 s      |
    /// | 4       | 240 s     | 192 – 288 s     |
    /// | 5+      | 900 s     | 720 – 1080 s    |
    public var nextRetryDelay: TimeInterval {
        let base: TimeInterval
        switch failureCount {
        case 0: base = 0        // first attempt — immediate
        case 1: base = 30
        case 2: base = 60
        case 3: base = 120
        case 4: base = 240
        default: base = 900     // 15 minutes cap
        }
        let jitter = base * Double.random(in: -0.2...0.2)
        return base + jitter
    }

    /// The absolute `Date` at which the next retry should fire.
    public var nextRetryDate: Date {
        let anchor = lastAttemptDate ?? purchaseDate
        return anchor.addingTimeInterval(nextRetryDelay)
    }

    /// `true` if the transaction should be retried right now.
    public var isDueForRetry: Bool {
        guard !isPermanentlyFailed else { return false }
        return Date() >= nextRetryDate
    }

    /// Maximum number of automatic retries before marking as permanently failed
    /// and surfacing a manual "contact support" error to the user.
    public static let maxAutoRetries = 6
}

// MARK: - PendingTransactionStore

public final class PendingTransactionStore {

    // MARK: Singleton

    /// Shared instance — registered in Swinject as `.container` scope.
    public static let shared = PendingTransactionStore()

    // MARK: Storage

    private let defaults: UserDefaults
    private let storageKey = "com.openedx.payment.pending_transactions"
    private let queue = DispatchQueue(
        label: "com.openedx.payment.pending_transactions_queue",
        attributes: []   // serial
    )

    // MARK: Init

    /// - Parameter suiteName: Pass an App Group identifier to share the store
    ///   with a BGTaskScheduler extension. Defaults to the standard suite.
    public init(suiteName: String? = nil) {
        if let suite = suiteName {
            self.defaults = UserDefaults(suiteName: suite) ?? .standard
        } else {
            self.defaults = .standard
        }
    }

    // MARK: - Public interface

    /// All pending transactions, sorted oldest-first.
    /// Safe to call from any thread — returns a decoded snapshot.
    public func allPending() -> [PendingTransaction] {
        queue.sync { loadAll() }
    }

    /// Transactions that are overdue for a retry attempt right now.
    public func duePending() -> [PendingTransaction] {
        allPending().filter { $0.isDueForRetry }
    }

    /// Add a new transaction to the pending store.
    /// No-op if a transaction with the same ID already exists.
    public func add(_ tx: PendingTransaction) {
        queue.sync {
            var all = loadAll()
            guard !all.contains(where: { $0.transactionID == tx.transactionID }) else {
                return
            }
            all.append(tx)
            save(all)
        }
    }

    /// Remove a successfully synced transaction from the store.
    public func remove(transactionID: UInt64) {
        queue.sync {
            var all = loadAll()
            all.removeAll { $0.transactionID == transactionID }
            save(all)
        }
    }

    /// Record a failed attempt — increments `failureCount` and updates
    /// `lastAttemptDate`. Marks as permanently failed if `maxAutoRetries`
    /// is exceeded.
    public func recordFailure(transactionID: UInt64) {
        queue.sync {
            var all = loadAll()
            guard let idx = all.firstIndex(where: { $0.transactionID == transactionID })
            else { return }

            all[idx].failureCount += 1
            all[idx].lastAttemptDate = Date()

            if all[idx].failureCount >= PendingTransaction.maxAutoRetries {
                all[idx].isPermanentlyFailed = true
            }

            save(all)
        }
    }

    /// Reset a permanently-failed transaction so the user can trigger a
    /// manual retry from the UI.
    public func resetFailure(transactionID: UInt64) {
        queue.sync {
            var all = loadAll()
            guard let idx = all.firstIndex(where: { $0.transactionID == transactionID })
            else { return }

            all[idx].failureCount = 0
            all[idx].lastAttemptDate = nil
            all[idx].isPermanentlyFailed = false

            save(all)
        }
    }

    /// Whether any transactions are pending (used to drive the UI badge/banner).
    public var hasAny: Bool {
        !allPending().isEmpty
    }

    /// Whether any transactions are in a permanently-failed state.
    public var hasPermanentFailures: Bool {
        allPending().contains { $0.isPermanentlyFailed }
    }

    // MARK: - Private

    private func loadAll() -> [PendingTransaction] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([PendingTransaction].self, from: data)
        else { return [] }
        return decoded.sorted { $0.purchaseDate < $1.purchaseDate }
    }

    private func save(_ transactions: [PendingTransaction]) {
        if let data = try? JSONEncoder().encode(transactions) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
