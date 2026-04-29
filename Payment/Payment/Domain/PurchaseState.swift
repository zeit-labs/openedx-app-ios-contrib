//
//  PurchaseState.swift
//  Payment
//
//  Created by Rawan Matar on 15/04/2026.
//

import Foundation
import StoreKit
import Core
import OEXFoundation

// MARK: - State machine

public enum PurchaseState: Equatable {

    case idle
    case purchasing(productID: String)
    case validating(productID: String, transactionID: UInt64)
    
    /// NEW: StoreKit transaction verified. Backend sync is pending (queued for retry).
    case syncing(transactionID: UInt64)

    case success(courseID: String, transactionID: UInt64)
    case error(PaymentError, recoverable: Bool)

    // MARK: Derived helpers

    public var isLoading: Bool {
        switch self {
        case .purchasing, .validating, .syncing: return true
        default: return false
        }
    }

    public var loadingMessage: String? {
        switch self {
        case .purchasing: return PaymentLocalization.Payment.purchasing
        case .validating: return PaymentLocalization.Payment.validating
        case .syncing:    return PaymentLocalization.Payment.syncing
        default: return nil
        }
    }

    public var productID: String? {
        switch self {
        case .purchasing(let id): return id
        case .validating(let id, _): return id
        default: return nil
        }
    }
}

// MARK: - PaymentError

public enum PaymentError: Error, Equatable {
    case productNotFound(productID: String)
    case purchaseCancelled
    case purchasePending
    case purchaseFailed(localizedDescription: String)
    case verificationFailed
    case transactionListenerFailed
    case backendEnrollmentFailed(statusCode: Int)
    case backendUnreachable
    case paymentsDisabled
    case storeNotAvailable

    public var userFacingMessage: String {
        switch self {
        case .productNotFound:
            return PaymentLocalization.Payment.Error.productNotFound
        case .purchaseCancelled:
            return PaymentLocalization.Payment.Error.cancelled
        case .purchasePending:
            return PaymentLocalization.Payment.Error.pending
        case .purchaseFailed(let desc):
            return desc
        case .verificationFailed:
            return PaymentLocalization.Payment.Error.verificationFailed
        case .backendEnrollmentFailed(let code):
            return String(format: PaymentLocalization.Payment.Error.backendFailed, code)
        case .backendUnreachable:
            return PaymentLocalization.Payment.Error.networkError
        case .paymentsDisabled:
            return PaymentLocalization.Payment.Error.disabled
        case .storeNotAvailable:
            return PaymentLocalization.Payment.Error.storeUnavailable
        case .transactionListenerFailed:
            return PaymentLocalization.Payment.Error.listenerFailed
        }
    }

    public var isRecoverable: Bool {
        switch self {
        case .purchaseCancelled, .backendUnreachable, .backendEnrollmentFailed:
            return true
        default:
            return false
        }
    }
}

// MARK: - Local Localization Stub
public enum PaymentLocalization {
    
    // MARK: - General UI Labels
    static let upgradeTitle         = "Course Upgrade"
    static let upgradeHeadline      = "Get the full course experience"
    static let upgradeSubheadline   = "Unlock graded assignments, a certificate, and unlimited access."
    static let oneTimePurchase      = "One-time purchase"
    static let upgradeForPrice      = "Upgrade for %@"
    static let upgradeNow           = "Upgrade Now"
    static let enrolled             = "Enrolled!"
    static let restorePurchases     = "Restore Purchases"
    static let tryAgain             = "Try Again"
    static let cancel               = "Cancel"
    static let purchaseErrorTitle   = "Purchase Error"
    
    // Using + ensures SwiftLint sees this as two short lines instead of one long one
    static let iapLegalFooter = "Payment will be charged to your Apple ID account. " +
                                "Purchases will be applied to your account upon confirmation."

    // MARK: - Status & Loading
    enum Payment {
        static let purchasing = "Processing purchase..."
        static let validating = "Verifying with server..."
        static let syncing    = "Completing your enrollment..."
        
        // MARK: - Error Messages
        enum Error {
            static let productNotFound = "Course upgrade is not available right now."
            static let cancelled       = "Purchase was cancelled."
            static let pending         = "Purchase is pending approval."
            static let verificationFailed = "Could not verify your purchase. Please contact support."
            static let backendFailed   = "Enrollment failed (error %d). Please try again."
            static let networkError    = "Network error. Please check your connection and try again."
            static let disabled        = "In-app purchases are not enabled for this app."
            static let storeUnavailable = "The App Store is not available right now."
            static let listenerFailed  = "Transaction listener error. Please restart the app."
        }
    }
}
