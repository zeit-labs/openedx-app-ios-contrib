//
//  PaymentAPI.swift
//  Payment
//
//  Created by Rawan Matar on 15/04/2026.
//

import Foundation
import Core
import OEXFoundation
import Alamofire

// MARK: - PaymentEndpoint

public enum PaymentEndpoint: EndPointType {
    case execute(
        receipt: String,
        courseID: String,
        bundleID: String,
        purchaseDate: String,
        transactionID: String
    )
    case pollEnrollmentStatus(transactionID: String)
    case reportRefund(courseID: String, transactionID: String)

    public var path: String {
        switch self {
        case .execute:
            return "/api/iap/v1/execute/"
        case .pollEnrollmentStatus:
            return "/api/iap/v1/basket/execute/"
        case .reportRefund:
            return "/api/iap/v1/refund/"
        }
    }

    public var httpMethod: HTTPMethod {
        switch self {
        case .execute, .reportRefund:
            return .post
        case .pollEnrollmentStatus:
            return .get
        }
    }

    public var headers: HTTPHeaders? {
        nil
    }

    public var task: HTTPTask {
        switch self {
        case let .execute(receipt, courseID, bundleID, purchaseDate, transactionID):
            let params: [String: Encodable & Sendable] = [
                "receipt": receipt,
                "course_id": courseID,
                "bundle_id": bundleID,
                "purchase_date": purchaseDate,
                "store_name": "apple",
                "transaction_id": transactionID
            ]
            return .requestParameters(parameters: params, encoding: JSONEncoding.default)
            
        case let .pollEnrollmentStatus(transactionID):
            let params: [String: Encodable & Sendable] = [
                "transaction_id": transactionID
            ]
            return .requestParameters(parameters: params, encoding: URLEncoding.queryString)
            
        case let .reportRefund(courseID, transactionID):
            let params: [String: Encodable & Sendable] = [
                "course_id": courseID,
                "transaction_id": transactionID
            ]
            return .requestParameters(parameters: params, encoding: JSONEncoding.default)
        }
    }
}

// MARK: - PaymentAPI (Models)

public enum PaymentAPI {
    public struct ExecuteRequest: Encodable {
        public let jwsRepresentation: String
        public let courseID: String
        public let bundleID: String
        public let purchaseDate: Date
        public let transactionID: UInt64
        
        public init(
            jwsRepresentation: String,
            courseID: String,
            bundleID: String,
            purchaseDate: Date,
            transactionID: UInt64
        ) {
            self.jwsRepresentation = jwsRepresentation
            self.courseID = courseID
            self.bundleID = bundleID
            self.purchaseDate = purchaseDate
            self.transactionID = transactionID
        }
    }

    public struct ExecuteResponse: Decodable {
        public let status: String
        public let courseId: String
        public let message: String?
        enum CodingKeys: String, CodingKey {
            case status
            case courseId = "course_id"
            case message
        }
        public var isProcessing: Bool { status == "processing" }
        public var isFulfilled: Bool { status == "fulfilled" }
    }

    public struct PollResponse: Decodable {
        public let status: String
        public let courseId: String?
        enum CodingKeys: String, CodingKey {
            case status
            case courseId = "course_id"
        }
    }
}
