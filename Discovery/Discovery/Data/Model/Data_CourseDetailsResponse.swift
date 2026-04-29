//
//  CourseDetailsResponse.swift
//  CourseDetails
//
//  Created by  Stepanok Ivan on 26.09.2022.
//

import Foundation
import Core

public extension DataLayer {
    
    // MARK: - CourseModeResponse
    struct CourseModeResponse: Codable {
        public let slug: String
        public let name: String
        public let price: Int
        public let currency: String
        public let iosSku: String?
        
        enum CodingKeys: String, CodingKey {
            case slug
            case name
            case price = "min_price"
            case currency
            case iosSku = "ios_sku"
        }
        
        var domain: Discovery.CourseMode {
            return Discovery.CourseMode(
                slug: slug,
                name: name,
                price: price,
                currency: currency,
                iosSku: iosSku
            )
        }
    }

    // MARK: - CourseDetailsResponse
    struct CourseDetailsResponse: Codable {
        public let blocksURL: String
        public let effort: String?
        public let end: String?
        public let enrollmentStart: String?
        public let enrollmentEnd: String?
        public let isEnrolled: Bool?
        public let id: String
        public let media: Media
        public let name: String
        public let number: String
        public let org: String
        public let shortDescription: String?
        public let start: String?
        public let startDisplay: String?
        public let startType: String?
        public let pacing: String
        public let mobileAvailable: Bool
        public let hidden: Bool
        public let invitationOnly: Bool
        public let courseID: String
        public let overview: String
        public let productId: String?
        public let courseModes: [CourseModeResponse]?
        
        enum CodingKeys: String, CodingKey {
            case blocksURL = "blocks_url"
            case effort
            case end
            case enrollmentStart = "enrollment_start"
            case enrollmentEnd = "enrollment_end"
            case isEnrolled = "is_enrolled"
            case id
            case media
            case name
            case number
            case org
            case shortDescription = "short_description"
            case start
            case startDisplay = "start_display"
            case startType = "start_type"
            case pacing
            case mobileAvailable = "mobile_available"
            case hidden
            case invitationOnly = "invitation_only"
            case courseID = "course_id"
            case overview
            case productId = "ios_sku"
            case courseModes = "course_modes"
        }
    }
}

public extension DataLayer.CourseDetailsResponse {
    func domain(baseURL: String) -> CourseDetails {
        let imageURL = baseURL + (media.courseImage?.url?.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? "")
        return CourseDetails(
            courseID: id,
            org: org,
            courseTitle: name,
            courseDescription: shortDescription,
            courseStart: start != nil ? Date(iso8601: start!) : nil,
            courseEnd: end != nil ? Date(iso8601: end!) : nil,
            enrollmentStart: enrollmentStart != nil ? Date(iso8601: enrollmentStart!) : nil,
            enrollmentEnd: enrollmentEnd != nil ? Date(iso8601: enrollmentEnd!) : nil,
            isEnrolled: isEnrolled ?? false,
            overviewHTML: overview,
            courseBannerURL: imageURL,
            courseVideoURL: media.courseVideo?.url,
            courseRawImage: media.image?.raw,
            iapProductID: productId,
            courseModes: courseModes?.map { $0.domain } ?? []
        )
    }
}
