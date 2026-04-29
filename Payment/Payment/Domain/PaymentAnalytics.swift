//
//  PaymentAnalytics.swift
//  Payment
//
//  Created by Rawan Matar on 26/04/2026.
//

import OEXFoundation

public protocol PaymentAnalytics: Sendable {
    func trackPaymentEvent(_ event: PaymentAnalyticsEvent)
}
