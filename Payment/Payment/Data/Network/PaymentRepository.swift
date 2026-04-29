//
//  PaymentRepository.swift
//  Payment
//
//  Created by Rawan Matar on 15/04/2026.
//

import Foundation
import StoreKit
import Core
import OEXFoundation
import Alamofire

// MARK: - PaymentRepositoryProtocol

public protocol PaymentRepositoryProtocol: Sendable {
    func syncPurchase(
        transaction: Transaction,
        jwsRepresentation: String,
        courseID: String
    ) async throws -> SyncResult

    @discardableResult
    func retryPendingTransactions() async -> [SyncResult]

    func manualRetry(transactionID: UInt64) async throws -> SyncResult

    var pendingTransactions: [PendingTransaction] { get }
}

// MARK: - SyncResult

public enum SyncResult: Equatable {
    case enrolled(courseID: String)
    case pending(transactionID: UInt64)
    case permanentFailure(transactionID: UInt64, reason: String)
}

// MARK: - PaymentRepository

public final class PaymentRepository: PaymentRepositoryProtocol {

    // MARK: Dependencies

    private let api: API
    private let store: PendingTransactionStore
    private let config: ConfigProtocol

    // MARK: Constants

    private let maxPollingAttempts = 10
    private let pollingInterval: TimeInterval = 3.0

    // MARK: Init

    public init(
        api: API,
        config: ConfigProtocol,
        store: PendingTransactionStore = .shared
    ) {
        self.api = api
        self.config = config
        self.store = store
    }

    // MARK: - PaymentRepositoryProtocol

    public var pendingTransactions: [PendingTransaction] {
        store.allPending()
    }

    public func syncPurchase(
        transaction: Transaction,
        jwsRepresentation: String,
        courseID: String
    ) async throws -> SyncResult {
        
        // 1. Create the pending record first to ensure it's saved if the app crashes
        let pending = PendingTransaction(
            transactionID: transaction.id,
            productID: transaction.productID,
            courseID: courseID,
            jwsRepresentation: jwsRepresentation,
            purchaseDate: transaction.purchaseDate,
            bundleID: Bundle.main.bundleIdentifier ?? ""
        )
        store.add(pending)

        // 2. Attempt initial sync
        return await attemptSync(pending: pending, transaction: transaction)
    }

    public func retryPendingTransactions() async -> [SyncResult] {
        let due = store.duePending()
        guard !due.isEmpty else { return [] }

        var results: [SyncResult] = []

        await withTaskGroup(of: SyncResult.self) { group in
            for pending in due {
                group.addTask { [weak self] in
                    guard let self else {
                        return .pending(transactionID: pending.transactionID)
                    }
                    return await self.attemptSync(pending: pending, transaction: nil)
                }
            }
            for await result in group {
                results.append(result)
            }
        }
        return results
    }

    public func manualRetry(transactionID: UInt64) async throws -> SyncResult {
        let allPending = store.allPending()
        guard let pending = allPending.first(where: { $0.transactionID == transactionID }) else {
            throw PaymentRepositoryError.transactionNotFound(transactionID)
        }
        store.resetFailure(transactionID: transactionID)
        return await attemptSync(pending: pending, transaction: nil)
    }

    // MARK: - Private: core sync attempt

    private func attemptSync(
        pending: PendingTransaction,
        transaction: Transaction?
    ) async -> SyncResult {

        let dateString = ISO8601DateFormatter().string(from: pending.purchaseDate)
        
        let endpoint = PaymentEndpoint.execute(
            receipt: pending.jwsRepresentation,
            courseID: pending.courseID,
            bundleID: pending.bundleID,
            purchaseDate: dateString,
            transactionID: String(pending.transactionID)
        )

        do {
            let response = try await api.requestData(endpoint)
                .mapResponse(PaymentAPI.ExecuteResponse.self)

            if response.isFulfilled {
                return await handleSuccess(
                    courseID: response.courseId,
                    transactionID: pending.transactionID,
                    transaction: transaction
                )
            } else if response.isProcessing {
                return await pollUntilFulfilled(
                    transactionID: pending.transactionID,
                    transaction: transaction,
                    courseID: pending.courseID
                )
            } else {
                let reason = response.message ?? "Server returned \(response.status)"
                return await handleFailure(
                    transactionID: pending.transactionID,
                    reason: reason,
                    isRetriable: true
                )
            }
        } catch {
            return await handleNetworkError(error, transactionID: pending.transactionID)
        }
    }

    // MARK: - Private: 202 polling loop

    private func pollUntilFulfilled(
        transactionID: UInt64,
        transaction: Transaction?,
        courseID: String
    ) async -> SyncResult {

        for _ in 1...maxPollingAttempts {
            try? await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))

            if Task.isCancelled { return .pending(transactionID: transactionID) }

            do {
                let endpoint = PaymentEndpoint.pollEnrollmentStatus(transactionID: String(transactionID))
                let response = try await api.requestData(endpoint)
                    .mapResponse(PaymentAPI.PollResponse.self)

                if response.status == "fulfilled" {
                    return await handleSuccess(
                        courseID: response.courseId ?? courseID,
                        transactionID: transactionID,
                        transaction: transaction
                    )
                } else if response.status != "processing" {
                    return await handleFailure(
                        transactionID: transactionID,
                        reason: "Backend status: \(response.status)",
                        isRetriable: false
                    )
                }
            } catch {
                continue
            }
        }

        return await handleFailure(
            transactionID: transactionID,
            reason: "Polling timeout",
            isRetriable: true
        )
    }

    // MARK: - Private: outcome handlers

    private func handleSuccess(
        courseID: String,
        transactionID: UInt64,
        transaction: Transaction?
    ) async -> SyncResult {
        store.remove(transactionID: transactionID)
        
        if let transaction = transaction {
            await transaction.finish()
        }
        
        return .enrolled(courseID: courseID)
    }
    
    private func handleFailure(
        transactionID: UInt64,
        reason: String,
        isRetriable: Bool
    ) async -> SyncResult {
        store.recordFailure(transactionID: transactionID)
        
        let pending = store.allPending().first { $0.transactionID == transactionID }
        let isPermanentlyFailed = pending?.isPermanentlyFailed ?? false
        let isPermanent = !isRetriable || isPermanentlyFailed
        
        if isPermanent {
            return .permanentFailure(transactionID: transactionID, reason: reason)
        }
        return .pending(transactionID: transactionID)
    }

    private func handleNetworkError(
            _ error: Error,
            transactionID: UInt64
        ) async -> SyncResult {
            var code: Int?
            
            if let afError = error as? AFError {
                code = afError.responseCode
            }
            
            if let code = code {
                let isClientError = (400..<500).contains(code)
                let isRetriable = !isClientError || code == 408 || code == 429
                
                return await handleFailure(
                    transactionID: transactionID,
                    reason: "Server Error \(code)",
                    isRetriable: isRetriable
                )
            }
            
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                return await handleFailure(
                    transactionID: transactionID,
                    reason: "Connectivity issue: \(error.localizedDescription)",
                    isRetriable: true
                )
            }

            return await handleFailure(
                transactionID: transactionID,
                reason: error.localizedDescription,
                isRetriable: true
            )
        }
}

public enum PaymentRepositoryError: Error {
    case transactionNotFound(UInt64)
}
