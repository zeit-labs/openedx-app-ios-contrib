//
//  CourseUpgradeViewModel.swift
//  Payment
//
//  Created by Rawan Matar on 15/04/2026.
//

import Foundation
import Combine
import Core
import OEXFoundation

// MARK: - Payment Analytics Events
public enum PaymentAnalyticsEvent {
    case upgradeButtonTapped(courseID: String, productID: String)
    case productLoadFailed(courseID: String, productID: String, error: Error)
    case purchaseCancelled(courseID: String, productID: String)
    case purchaseFailed(courseID: String, productID: String, error: Error)
    case purchaseSuccess(courseID: String, productID: String, transactionID: UInt64)
    case validationFailed(courseID: String, productID: String, error: Error)
    case purchaseRevoked(productID: String, transactionID: UInt64)
    case verificationFailed(courseID: String, error: Error)
    case restoreTapped(courseID: String)
}

@MainActor
public final class CourseUpgradeViewModel: ObservableObject {

    // MARK: - Published State
    @Published public private(set) var purchaseState: PurchaseState = .idle
    @Published public private(set) var upgradeProduct: StoreProduct?
    @Published public private(set) var isLoadingProduct: Bool = false
    @Published public private(set) var productLoadError: String?

    // MARK: - Dependencies
    private let paymentService: PaymentServiceProtocol
    private let courseInteractor: CourseStructureManagerProtocol
    private let analytics: PaymentAnalytics

    // MARK: - Properties
    private let courseID: String
    private let productID: String
    private var transactionListenerTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init
    public init(
        courseID: String,
        productID: String,
        paymentService: PaymentServiceProtocol,
        courseInteractor: CourseStructureManagerProtocol,
        analytics: PaymentAnalytics
    ) {
        self.courseID = courseID
        self.productID = productID
        self.paymentService = paymentService
        self.courseInteractor = courseInteractor
        self.analytics = analytics

        startTransactionListener()
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    // MARK: - Public Interface

    /// Loads the App Store product details.
    public func loadProduct() {
        print("🟠🟠🟠🟠🟠🟠🟠loadProduct 🟠🟠🟠🟠🟠🟠🟠🟠")
        guard upgradeProduct == nil, !isLoadingProduct else { return }
        isLoadingProduct = true
        productLoadError = nil

        Task {
            defer { isLoadingProduct = false }
            do {
                let products = try await paymentService.fetchProducts(productIDs: [productID])
                guard let product = products.first else {
                    productLoadError = PaymentLocalization.Payment.Error.productNotFound
                    return
                }
                upgradeProduct = product
            } catch let error as PaymentError {
                productLoadError = error.userFacingMessage
                analytics.trackPaymentEvent(
                    .productLoadFailed(courseID: courseID, productID: productID, error: error)
                )
            } catch {
                productLoadError = PaymentLocalization.Payment.Error.storeUnavailable
            }
        }
    }

    /// Triggers the purchase flow when the user taps the Upgrade button.
    public func upgradeTapped() {
        guard case .idle = purchaseState else { return }
        guard let product = upgradeProduct else {
            purchaseState = .error(.productNotFound(productID: productID), recoverable: false)
            return
        }

        analytics.trackPaymentEvent(.upgradeButtonTapped(courseID: courseID, productID: productID))

        Task {
            await performPurchase(product: product)
        }
    }

    /// Triggers the App Store restore flow.
    public func restorePurchasesTapped() {
        guard case .idle = purchaseState else { return }
        analytics.trackPaymentEvent(.restoreTapped(courseID: courseID))

        Task {
            purchaseState = .purchasing(productID: productID)
            do {
                try await paymentService.restorePurchases()
                // Wait 3 seconds for stream, then reset to idle if nothing arrived.
                try await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                if case .purchasing = purchaseState {
                    purchaseState = .idle
                }
            } catch let error as PaymentError {
                purchaseState = error == .purchaseCancelled ? .idle : .error(error, recoverable: error.isRecoverable)
            } catch {
                purchaseState = .error(.storeNotAvailable, recoverable: true)
            }
        }
    }

    public func dismissError() {
        if case .error = purchaseState {
            purchaseState = .idle
        }
    }

    // MARK: - Private Purchase Logic

    private func performPurchase(product: StoreProduct) async {
        purchaseState = .purchasing(productID: product.id)

        do {
            let result = try await paymentService.purchase(product: product, courseID: courseID)
            await enrollAfterValidation(result: result)
        } catch let error as PaymentError where error == .purchaseCancelled {
            purchaseState = .idle
            analytics.trackPaymentEvent(.purchaseCancelled(courseID: courseID, productID: product.id))
        } catch let error as PaymentError {
            purchaseState = .error(error, recoverable: error.isRecoverable)
            analytics.trackPaymentEvent(.purchaseFailed(courseID: courseID, productID: product.id, error: error))
        } catch {
            let wrappedError = PaymentError.purchaseFailed(localizedDescription: error.localizedDescription)
            purchaseState = .error(wrappedError, recoverable: true)
        }
    }

    private func enrollAfterValidation(result: PurchaseResult) async {
        purchaseState = .validating(productID: result.productID, transactionID: result.transactionID)

        do {
            let confirmedCourseID = try await paymentService.validateWithBackend(
                result: result,
                courseID: courseID
            )

            // Refresh the course blocks via interactor
            _ = try? await courseInteractor.getLoadedCourseBlocks(courseID: confirmedCourseID)

            purchaseState = .success(
                courseID: confirmedCourseID,
                transactionID: result.transactionID
            )

            analytics.trackPaymentEvent(.purchaseSuccess(
                courseID: confirmedCourseID,
                productID: result.productID,
                transactionID: result.transactionID
            ))
        } catch let error as PaymentError {
            purchaseState = .error(error, recoverable: error.isRecoverable)
            analytics.trackPaymentEvent(
                .validationFailed(courseID: courseID, productID: result.productID, error: error)
            )
        } catch {
            purchaseState = .error(.backendUnreachable, recoverable: true)
        }
    }

    // MARK: - Transaction Listener
    
    private func startTransactionListener() {
        transactionListenerTask = Task {
            for await update in paymentService.transactionUpdates {
                switch update {
                case .verified(let result):
                    guard result.productID == productID else { continue }
                    await enrollAfterValidation(result: result)

                case .revoked(let txID, let pid):
                    analytics.trackPaymentEvent(.purchaseRevoked(productID: pid, transactionID: txID))

                case .unverified(_, let error):
                    analytics.trackPaymentEvent(.verificationFailed(courseID: courseID, error: error))
                }
            }
        }
    }
}
