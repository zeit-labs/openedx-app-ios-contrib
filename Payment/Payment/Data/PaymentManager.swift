//
//  PaymentManager.swift
//  Payment
//
//  Created by Rawan Matar on 15/04/2026.
//

import Foundation
import StoreKit
import Core
import OEXFoundation
import CommonCrypto
import Alamofire

// MARK: - PaymentManager

public final class PaymentManager: PaymentServiceProtocol {

    // MARK: Dependencies
    private let api: API
    private let config: ConfigProtocol

    // MARK: Transaction update stream

    private let updatesContinuation: AsyncStream<TransactionUpdate>.Continuation
    public let transactionUpdates: AsyncStream<TransactionUpdate>
    private var listenerTask: Task<Void, Never>?

    // MARK: Init

    public init(api: API, config: ConfigProtocol) {
        self.api = api
        self.config = config

        var cont: AsyncStream<TransactionUpdate>.Continuation!
        self.transactionUpdates = AsyncStream { continuation in
            cont = continuation
        }
        self.updatesContinuation = cont

        self.listenerTask = Task(priority: .utility) { [weak self] in
            await self?.startTransactionListener()
        }
    }

    deinit {
        listenerTask?.cancel()
        updatesContinuation.finish()
    }

    // MARK: - PaymentServiceProtocol: fetchProducts

    public func fetchProducts(productIDs: Set<String>) async throws -> [StoreProduct] {
        guard config.isPaymentsEnabled else {
            print("PaymentError.paymentsDisabled: \(PaymentError.paymentsDisabled)")
            throw PaymentError.paymentsDisabled
        }

        print("DEBUG IAP: Fetching products for: \(productIDs)")
        let products: [Product]
        do {
            products = try await Product.products(for: productIDs)
            print("DEBUG IAP: Found \(products.count) products from Apple")
            for p in products {
                    print("DEBUG IAP: Found ID: \(p.id)")
            }
        } catch {
            throw PaymentError.storeNotAvailable
        }

        guard !products.isEmpty else {
            throw PaymentError.productNotFound(productID: productIDs.joined(separator: ", "))
        }

        return products.map(StoreProduct.init)
    }

    // MARK: - PaymentServiceProtocol: purchase

    public func purchase(
        product: StoreProduct,
        courseID: String
    ) async throws -> PurchaseResult {
        guard config.isPaymentsEnabled else {
            throw PaymentError.paymentsDisabled
        }

        let courseToken = UUID(courseID: courseID) ?? UUID()

        let purchaseResult: Product.PurchaseResult
        do {
            purchaseResult = try await product.underlyingProduct.purchase(
                options: [.appAccountToken(courseToken)]
            )
        } catch StoreKitError.userCancelled {
            throw PaymentError.purchaseCancelled
        } catch {
            throw PaymentError.purchaseFailed(localizedDescription: error.localizedDescription)
        }

        switch purchaseResult {
        case .success(let verificationResult):
            return try extractVerifiedResult(from: verificationResult)
        case .pending:
            throw PaymentError.purchasePending
        case .userCancelled:
            throw PaymentError.purchaseCancelled
        @unknown default:
            throw PaymentError.purchaseFailed(localizedDescription: "Unknown purchase result.")
        }
    }

    // MARK: - PaymentServiceProtocol: restorePurchases

    public func restorePurchases() async throws {
        do {
            try await AppStore.sync()
        } catch {
            throw PaymentError.storeNotAvailable
        }
    }

    // MARK: - PaymentServiceProtocol: validateWithBackend

    @discardableResult
    public func validateWithBackend(
        result: PurchaseResult,
        courseID: String
    ) async throws -> String {
        
        // 1. Prepare request data
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let dateString = ISO8601DateFormatter().string(from: Date())
        
        // 2. Use the new PaymentEndpoint enum (EndPointType)
        let endpoint = PaymentEndpoint.execute(
            receipt: result.jwsRepresentation,
            courseID: courseID,
            bundleID: bundleID,
            purchaseDate: dateString,
            transactionID: String(result.transactionID)
        )

        do {
            // 3. Match the project pattern: api.requestData(endpoint).mapResponse(Type.self)
            let response = try await api.requestData(endpoint)
                .mapResponse(PaymentAPI.ExecuteResponse.self)
            
            await result.transaction.finish()
            return response.courseId
        } catch {
            // 4. Handle error without the 'errorStatusCode' extension
            if let afError = error as? AFError, let code = afError.responseCode {
                throw PaymentError.backendEnrollmentFailed(statusCode: code)
            }
            throw PaymentError.backendUnreachable
        }
    }

    // MARK: - Private: transaction listener

    private func startTransactionListener() async {
        for await update in Transaction.updates {
            do {
                let result = try extractVerifiedResult(from: update)
                updatesContinuation.yield(.verified(result))
            } catch {
                updatesContinuation.yield(.unverified(transactionID: 0, error: error))
            }
        }
    }

    // MARK: - Private: helpers

    private func extractVerifiedResult(
        from verificationResult: VerificationResult<Transaction>
    ) throws -> PurchaseResult {
        switch verificationResult {
        case .unverified:
            throw PaymentError.verificationFailed
        case .verified(let transaction):
            return PurchaseResult(
                transactionID: transaction.id,
                productID: transaction.productID,
                jwsRepresentation: verificationResult.jwsRepresentation,
                appAccountToken: transaction.appAccountToken,
                transaction: transaction
            )
        }
    }
}

// MARK: - StoreProduct init

private extension StoreProduct {
    init(_ product: Product) {
        self.init(
            id: product.id,
            displayName: product.displayName,
            displayPrice: product.displayPrice,
            price: product.price,
            currencyCode: product.priceFormatStyle.currencyCode,
            underlyingProduct: product
        )
    }
}

// MARK: - UUID+CourseID

private extension UUID {
    init?(courseID: String) {
        guard !courseID.isEmpty else { return nil }
        let namespace = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
        self = UUID.v5(name: courseID, namespace: namespace)
    }

    static func v5(name: String, namespace: UUID) -> UUID {
        var nsBytes = withUnsafeBytes(of: namespace.uuid, Array.init)
        nsBytes += Array(name.utf8)
        var digest = [UInt8](repeating: 0, count: 20)
        nsBytes.withUnsafeBytes { ptr in
            _ = CC_SHA1(ptr.baseAddress, CC_LONG(ptr.count), &digest)
        }
        digest[6] = (digest[6] & 0x0F) | 0x50
        digest[8] = (digest[8] & 0x3F) | 0x80
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }
}
