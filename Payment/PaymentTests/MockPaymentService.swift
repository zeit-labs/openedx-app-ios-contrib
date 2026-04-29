// MockPaymentService.swift
// PaymentTests / Mocks
//
// Follows the same mock pattern used throughout openedx-app-ios:
// concrete class implementing the protocol, with recorded calls and
// configurable stubs. Generated via the MockTemplate.swifttemplate pattern
// in the repo root.
//
// Usage:
//   let mock = MockPaymentService()
//   mock.fetchProductsResult = .success([.stub(id: "course.verified")])
//   let sut = CourseUpgradeViewModel(..., paymentService: mock, ...)

import Foundation
@testable import Payment   // adjust module name to match your target

// MARK: - MockPaymentService

final class MockPaymentService: PaymentServiceProtocol {

    // MARK: Call counts (assertion helpers)
    var fetchProductsCallCount = 0
    var purchaseCallCount = 0
    var restoreCallCount = 0
    var validateCallCount = 0

    // MARK: Captured arguments

    var fetchProductsCalledWithIDs: Set<String>?
    var purchaseCalledWithProduct: StoreProduct?
    var purchaseCalledWithCourseID: String?
    var validateCalledWithResult: PurchaseResult?
    var validateCalledWithCourseID: String?

    // MARK: Configurable return values

    var fetchProductsResult: Result<[StoreProduct], Error> = .success([])
    var purchaseResult: Result<PurchaseResult, Error> = .failure(
        PaymentError.purchaseCancelled
    )
    var restoreResult: Result<Void, Error> = .success(())
    var validateResult: Result<String, Error> = .success("course-123")

    // MARK: Transaction stream control

    private var updatesCont: AsyncStream<TransactionUpdate>.Continuation!
    let transactionUpdates: AsyncStream<TransactionUpdate>

    init() {
        var cont: AsyncStream<TransactionUpdate>.Continuation!
        self.transactionUpdates = AsyncStream { continuation in
            cont = continuation
        }
        self.updatesCont = cont
    }

    /// Emit a transaction update event from tests.
    func emitTransactionUpdate(_ update: TransactionUpdate) {
        updatesCont.yield(update)
    }

    // MARK: Protocol conformance

    func fetchProducts(productIDs: Set<String>) async throws -> [StoreProduct] {
        fetchProductsCallCount += 1
        fetchProductsCalledWithIDs = productIDs
        return try fetchProductsResult.get()
    }

    func purchase(product: StoreProduct, courseID: String) async throws -> PurchaseResult {
        purchaseCallCount += 1
        purchaseCalledWithProduct = product
        purchaseCalledWithCourseID = courseID
        return try purchaseResult.get()
    }

    func restorePurchases() async throws {
        restoreCallCount += 1
        try restoreResult.get()
    }

    func validateWithBackend(result: PurchaseResult, courseID: String) async throws -> String {
        validateCallCount += 1
        validateCalledWithResult = result
        validateCalledWithCourseID = courseID
        return try validateResult.get()
    }
}

// MARK: - Test stubs

extension StoreProduct {
    static func stub(
        id: String = "org.openedx.course.verified",
        displayName: String = "Verified Certificate",
        displayPrice: String = "$49.99",
        price: Decimal = 49.99
    ) -> StoreProduct {
        // NOTE: `underlyingProduct` is a StoreKit type that can't be instantiated
        // in unit tests without entitlements. Use the StoreKit Testing framework
        // (SKTestSession) for integration tests, and this stub for pure unit tests
        // where `underlyingProduct` is never accessed.
        StoreProduct(
            id: id,
            displayName: displayName,
            displayPrice: displayPrice,
            price: price,
            currencyCode: "USD",
            underlyingProduct: unsafeBitCast(0 as Int, to: Product.self)
            // ↑ Never called in unit tests — safe because purchase() is mocked.
        )
    }
}

extension PurchaseResult {
    static func stub(
        transactionID: UInt64 = 42,
        productID: String = "org.openedx.course.verified",
        courseID: String = "course-v1:edX+DemoX+Demo_Course"
    ) -> PurchaseResult {
        PurchaseResult(
            transactionID: transactionID,
            productID: productID,
            jwsRepresentation: "stub.jws.token",
            appAccountToken: UUID(courseID: courseID),
            transaction: unsafeBitCast(0 as Int, to: Transaction.self)
            // ↑ Never called in unit tests — transaction.finish() is behind validateWithBackend mock.
        )
    }
}

// MARK: - Example unit test (XCTest)

/*
import XCTest

@MainActor
final class CourseUpgradeViewModelTests: XCTestCase {

    var mockService: MockPaymentService!
    var mockInteractor: MockCourseInteractor!
    var sut: CourseUpgradeViewModel!

    override func setUp() {
        super.setUp()
        mockService = MockPaymentService()
        mockInteractor = MockCourseInteractor()
        sut = CourseUpgradeViewModel(
            courseID: "course-v1:edX+DemoX+Demo_Course",
            productID: "org.openedx.course.verified",
            paymentService: mockService,
            courseInteractor: mockInteractor,
            analytics: MockAnalytics()
        )
    }

    func test_upgradeTapped_successFlow_setsSuccessState() async throws {
        // Arrange
        let product = StoreProduct.stub()
        mockService.fetchProductsResult = .success([product])
        mockService.purchaseResult = .success(.stub())
        mockService.validateResult = .success("course-v1:edX+DemoX+Demo_Course")

        // Act — simulate onAppear then user tap
        sut.loadProduct()
        try await Task.sleep(for: .milliseconds(100))

        sut.upgradeTapped()
        try await Task.sleep(for: .milliseconds(100))

        // Assert
        if case .success(let cid, _) = sut.purchaseState {
            XCTAssertEqual(cid, "course-v1:edX+DemoX+Demo_Course")
        } else {
            XCTFail("Expected .success, got \(sut.purchaseState)")
        }
        XCTAssertEqual(mockInteractor.invalidateCacheCallCount, 1)
    }

    func test_upgradeTapped_cancellation_returnsToIdle() async throws {
        let product = StoreProduct.stub()
        mockService.fetchProductsResult = .success([product])
        mockService.purchaseResult = .failure(PaymentError.purchaseCancelled)

        sut.loadProduct()
        try await Task.sleep(for: .milliseconds(100))
        sut.upgradeTapped()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(sut.purchaseState, .idle)
    }

    func test_backendFailure_setsRecoverableError() async throws {
        let product = StoreProduct.stub()
        mockService.fetchProductsResult = .success([product])
        mockService.purchaseResult = .success(.stub())
        mockService.validateResult = .failure(PaymentError.backendUnreachable)

        sut.loadProduct()
        try await Task.sleep(for: .milliseconds(100))
        sut.upgradeTapped()
        try await Task.sleep(for: .milliseconds(100))

        if case .error(let err, let recoverable) = sut.purchaseState {
            XCTAssertEqual(err, .backendUnreachable)
            XCTAssertTrue(recoverable)
        } else {
            XCTFail("Expected .error")
        }
    }
}

final class MockCourseInteractor: CourseInteractorProtocol {
    var invalidateCacheCallCount = 0
    func invalidateEnrollmentCache() async { invalidateCacheCallCount += 1 }
}

final class MockAnalytics: AnalyticsProtocol {
    func trackPaymentEvent(_ event: PaymentAnalyticsEvent) {}
}
*/
