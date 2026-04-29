//
//  CourseUpgradeView.swift
//  Payment
//
//  Created by Rawan Matar on 15/04/2026.
//

import SwiftUI
import Core
import OEXFoundation
import Theme

// MARK: - CourseUpgradeView

public struct CourseUpgradeView: View {

    @ObservedObject var viewModel: CourseUpgradeViewModel

    var onSuccess: (String) -> Void   // courseID
    var onDismiss: () -> Void

    public var body: some View {
        NavigationStack { // iOS 16+ standard
            ZStack {
                contentView
                    .disabled(viewModel.purchaseState.isLoading)

                if viewModel.purchaseState.isLoading {
                    loadingOverlay
                }
            }
            .navigationTitle(PaymentLocalization.upgradeTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    closeButton
                }
            }
        }
        .onAppear { viewModel.loadProduct() }
        .onChange(of: viewModel.purchaseState) { newState in
            if case .success(let courseID, _) = newState {
                // Delay dismissal slightly to allow the checkmark/success state to be seen
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    onSuccess(courseID)
                }
            }
        }
        .alert(
            PaymentLocalization.purchaseErrorTitle,
            isPresented: Binding(
                get: { if case .error = viewModel.purchaseState { return true }
                      return false },
                set: { if !$0 { viewModel.dismissError() } }
            ),
            presenting: errorDetails
        ) { detail in
            if detail.recoverable {
                Button(PaymentLocalization.tryAgain) { viewModel.upgradeTapped() }
            }
            Button(PaymentLocalization.cancel, role: .cancel) {
                viewModel.dismissError()
            }
        } message: { detail in
            Text(detail.message)
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var contentView: some View {
        if viewModel.isLoadingProduct {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.productLoadError {
            productLoadErrorView(message: error)
        } else if let product = viewModel.upgradeProduct {
            upgradeContentView(product: product)
        } else {
            Color.clear
        }
    }

    private func upgradeContentView(product: StoreProduct) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                upgradeHeroSection
                priceCard(product: product)
                benefitsList
                Spacer(minLength: 20)
                actionButtonStack(product: product)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
    }

    private var upgradeHeroSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "star.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.yellow, Color.accentColor)

            Text(PaymentLocalization.upgradeHeadline)
                .font(Theme.Fonts.titleMedium) // Use App Theme
                .multilineTextAlignment(.center)

            Text(PaymentLocalization.upgradeSubheadline)
                .font(Theme.Fonts.labelLarge)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func priceCard(product: StoreProduct) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(product.displayName)
                    .font(Theme.Fonts.labelLarge.weight(.bold))
                Text(PaymentLocalization.oneTimePurchase)
                    .font(Theme.Fonts.labelSmall)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(product.displayPrice)
                .font(Theme.Fonts.titleMedium.weight(.bold))
                .foregroundStyle(Color.accentColor)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var benefitsList: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(upgradebenefits, id: \.title) { benefit in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(benefit.title).font(Theme.Fonts.labelLarge.weight(.medium))
                        Text(benefit.description).font(Theme.Fonts.labelSmall).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: benefit.iconName)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func actionButtonStack(product: StoreProduct) -> some View {
        VStack(spacing: 12) {
            Button {
                viewModel.upgradeTapped()
            } label: {
                HStack {
                    if case .success = viewModel.purchaseState {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    Text(purchaseCTALabel(product: product))
                        .font(Theme.Fonts.labelLarge.weight(.bold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.purchaseState.isLoading)

            Button(PaymentLocalization.restorePurchases) {
                viewModel.restorePurchasesTapped()
            }
            .font(Theme.Fonts.labelSmall)
            .foregroundStyle(.secondary)
            .disabled(viewModel.purchaseState.isLoading)

            Text(PaymentLocalization.iapLegalFooter)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }

    private func productLoadErrorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(message)
                .font(Theme.Fonts.labelLarge)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(PaymentLocalization.tryAgain) { viewModel.loadProduct() }
                .buttonStyle(.bordered)
        }
        .padding(32)
    }

    private var loadingOverlay: some View {
        ZStack {
            Color(.systemBackground).opacity(0.7)
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.4)
                if let message = viewModel.purchaseState.loadingMessage {
                    Text(message)
                        .font(Theme.Fonts.labelMedium)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.secondarySystemBackground))
                    .shadow(radius: 12)
            )
        }
        .ignoresSafeArea()
    }

    private var closeButton: some View {
        Button {
            guard !viewModel.purchaseState.isLoading else { return }
            onDismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func purchaseCTALabel(product: StoreProduct) -> String {
        switch viewModel.purchaseState {
        case .idle:
            return String(format: PaymentLocalization.upgradeForPrice, product.displayPrice)
        case .purchasing:
            return PaymentLocalization.Payment.purchasing
        case .validating, .syncing: // Added syncing state
            return PaymentLocalization.Payment.validating
        case .success:
            return PaymentLocalization.enrolled
        case .error:
            return PaymentLocalization.tryAgain
        }
    }

    private struct ErrorDetails {
        let message: String
        let recoverable: Bool
    }

    private var errorDetails: ErrorDetails? {
        if case .error(let err, let recoverable) = viewModel.purchaseState {
            return ErrorDetails(message: err.userFacingMessage, recoverable: recoverable)
        }
        return nil
    }
}

// MARK: - CourseDetailsView integration point

extension View {
    public func courseUpgradeSheet(
        isPresented: Binding<Bool>,
        viewModel: CourseUpgradeViewModel,
        onSuccess: @escaping (String) -> Void
    ) -> some View {
        self.sheet(isPresented: isPresented) {
            CourseUpgradeView(
                viewModel: viewModel,
                onSuccess: { courseID in
                    isPresented.wrappedValue = false
                    onSuccess(courseID)
                },
                onDismiss: { isPresented.wrappedValue = false }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - UpgradeButtonView

public struct UpgradeButtonView: View {
    public let price: String?
    public let action: () -> Void

    public init(price: String?, action: @escaping () -> Void) {
        self.price = price
        self.action = action
    }
    
    public var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: "arrow.up.circle.fill")
                Text(price.map { String(format: PaymentLocalization.upgradeForPrice, $0) }
                     ?? PaymentLocalization.upgradeNow)
                    .font(Theme.Fonts.labelLarge.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
        }
        .buttonStyle(.borderedProminent)
    }
}

// MARK: - Benefits data

private struct UpgradeBenefit {
    let iconName: String
    let title: String
    let description: String
}

private let upgradebenefits: [UpgradeBenefit] = [
    .init(iconName: "doc.badge.checkmark",
          title: "Graded assignments",
          description: "Submit work and get real feedback"),
    .init(iconName: "rosette",
          title: "Course certificate",
          description: "Shareable credential for your profile"),
    .init(iconName: "infinity",
          title: "Unlimited access",
          description: "No expiry on course content"),
    .init(iconName: "person.crop.circle.badge.checkmark",
          title: "Instructor support",
          description: "Access the course discussion forums")
]
