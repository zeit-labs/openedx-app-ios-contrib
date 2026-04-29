//
//  CourseDetails.swift
//  CourseDetails
//
//  Created by  Stepanok Ivan on 26.09.2022.
//

import Foundation

public struct CourseMode: Codable, Sendable {
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
}

public struct CourseDetails: Sendable {
    public let courseID: String
    public let org: String
    public let courseTitle: String
    public let courseDescription: String?
    public let courseStart: Date?
    public let courseEnd: Date?
    public let enrollmentStart: Date?
    public let enrollmentEnd: Date?
    public var isEnrolled: Bool
    public var overviewHTML: String
    public let courseBannerURL: String
    public let courseVideoURL: String?
    public let courseRawImage: String?
    public let iapProductID: String?
    public let courseModes: [CourseMode]?
    
    public init(courseID: String,
                org: String,
                courseTitle: String,
                courseDescription: String?,
                courseStart: Date?,
                courseEnd: Date?,
                enrollmentStart: Date?,
                enrollmentEnd: Date?,
                isEnrolled: Bool,
                overviewHTML: String,
                courseBannerURL: String,
                courseVideoURL: String?,
                courseRawImage: String?,
                iapProductID: String?,
                courseModes: [CourseMode]?
    ) {
        self.courseID = courseID
        self.org = org
        self.courseTitle = courseTitle
        self.courseDescription = courseDescription
        self.courseStart = courseStart
        self.courseEnd = courseEnd
        self.enrollmentStart = enrollmentStart
        self.enrollmentEnd = enrollmentEnd
        self.isEnrolled = isEnrolled
        self.overviewHTML = overviewHTML
        self.courseBannerURL = courseBannerURL
        self.courseVideoURL = courseVideoURL
        self.courseRawImage = courseRawImage
        self.iapProductID = iapProductID
        self.courseModes = courseModes
    }
    
    public var isUpgradeAvailable: Bool {
            return iapProductID != nil && !iapProductID!.isEmpty
        }
}
