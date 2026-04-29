//
//  PaymentSyncService.swift
//  Payment
//
//  Created by Rawan Matar on 15/04/2026.
//

import Foundation
import StoreKit
import Core
import OEXFoundation
// MARK: - Primary protocol

public protocol PaymentServiceProtocol: AnyObject {

    // MARK: Product catalogue

    /// Fetch StoreKit products for the given App Store product IDs.
    /// - Parameter productIDs: Set of product ID strings defined in App Store Connect.
    /// - Returns: Array of `StoreProduct` value types (wraps `Product`).
    func fetchProducts(productIDs: Set<String>) async throws -> [StoreProduct]

    // MARK: Purchase

    /// Initiate a purchase for a single product.
    /// This suspends until the StoreKit payment sheet is dismissed and the
    /// transaction is either confirmed, cancelled, or deferred.
    ///
    /// - Parameters:
    ///   - product:   The `StoreProduct` to purchase.
    ///   - courseID:  Open edX course ID — passed as `appAccountToken` metadata
    ///                so it survives process restarts and receipt re-validation.
    /// - Returns: A verified `PurchaseResult` ready for backend validation.
    func purchase(
        product: StoreProduct,
        courseID: String
    ) async throws -> PurchaseResult

    // MARK: Restore

    /// Triggers App Store restore flow.
    /// Posts verified unfinished transactions back through `transactionUpdates`.
    func restorePurchases() async throws

    // MARK: Backend validation

    /// Send the JWS transaction representation to the Open edX commerce backend
    /// for server-side verification and course enrollment.
    ///
    /// - Parameters:
    ///   - result:    The verified purchase result from StoreKit.
    ///   - courseID:  Target course to enroll the user in.
    /// - Returns: The confirmed course ID (echoed from backend).
    @discardableResult
    func validateWithBackend(
        result: PurchaseResult,
        courseID: String
    ) async throws -> String

    // MARK: Transaction listener

    /// An `AsyncStream` that emits `TransactionUpdate` events for ALL unfinished
    /// transactions, including those from other devices. Observe this from app
    /// launch to handle interrupted purchases and family sharing.
    var transactionUpdates: AsyncStream<TransactionUpdate> { get }
}

// MARK: - Value types (wraps SK2 types for testability)

/// Thin wrapper around `StoreKit.Product` so ViewModels don't import StoreKit directly.
public struct StoreProduct: Identifiable, Equatable, Sendable {
    public let id: String               // == productIdentifier
    public let displayName: String
    public let displayPrice: String     // Localised, e.g. "$49.99"
    public let price: Decimal
    public let currencyCode: String?

    // Keep the raw SK2 product for purchase calls; not included in Equatable.
    let underlyingProduct: Product

    public static func == (lhs: StoreProduct, rhs: StoreProduct) -> Bool {
        lhs.id == rhs.id && lhs.price == rhs.price
    }
}

/// Result of a successful, locally-verified StoreKit purchase.
public struct PurchaseResult: Sendable {
    public let transactionID: UInt64
    public let productID: String
    /// JWS representation — send to backend as-is for server-side verification.
    public let jwsRepresentation: String
    /// The `appAccountToken` UUID we embedded at purchase time (contains courseID).
    public let appAccountToken: UUID?
    let transaction: Transaction        // held to call `.finish()` after backend ack
}

/// Events the transaction listener emits.
public enum TransactionUpdate: Sendable {
    case verified(PurchaseResult)
    case unverified(transactionID: UInt64, error: Error)
    case revoked(transactionID: UInt64, productID: String)
}
