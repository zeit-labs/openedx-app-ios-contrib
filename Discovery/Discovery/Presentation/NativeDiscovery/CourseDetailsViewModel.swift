//
//  ProfileViewModel.swift
//  Profile
//
//  Created by  Stepanok Ivan on 22.09.2022.
//

import Foundation
import Core
import SwiftUI
import Payment
import Swinject

public enum CourseState {
    case enrollOpen
    case enrollClose
    case alreadyEnrolled
}

@MainActor
public final class CourseDetailsViewModel: ObservableObject {
    
    @Published var courseDetails: CourseDetails?
    @Published private(set) var isShowProgress = false
    @Published var showError: Bool = false
    @Published var isHorisontal: Bool = false
    @Published var showUpgradeSheet: Bool = false
    var upgradeViewModel: CourseUpgradeViewModel?
    
    var errorMessage: String? {
        didSet {
            withAnimation {
                showError = errorMessage != nil
            }
        }
    }
    
    private let interactor: DiscoveryInteractorProtocol
    private let analytics: DiscoveryAnalytics
    let router: DiscoveryRouter
    let config: ConfigProtocol
    let cssInjector: CSSInjector
    let connectivity: ConnectivityProtocol
    let storage: CoreStorage
    private let container: Swinject.Container
    
    var userloggedIn: Bool {
        return !(storage.user?.username?.isEmpty ?? true)
    }
    
    public init(
        interactor: DiscoveryInteractorProtocol,
        router: DiscoveryRouter,
        analytics: DiscoveryAnalytics,
        config: ConfigProtocol,
        cssInjector: CSSInjector,
        connectivity: ConnectivityProtocol,
        storage: CoreStorage,
        container: Swinject.Container
    ) {
        self.interactor = interactor
        self.router = router
        self.analytics = analytics
        self.config = config
        self.cssInjector = cssInjector
        self.connectivity = connectivity
        self.storage = storage
        self.container = container
    }
    
    @MainActor
    func getCourseDetail(courseID: String, withProgress: Bool = true) async {
        isShowProgress = withProgress
        do {
            if connectivity.isInternetAvaliable {
                courseDetails = try await interactor.getCourseDetails(courseID: courseID)
                print("🟡🟡🟡🟡🟡🟡 getCourseDetail 🟡🟡🟡🟡🟡🟡\n \(courseDetails?.courseModes)")
//                if let sku = courseDetails?.courseModes?.first(where: { $0.slug == "verified" })?.iosSku {
                    print("🛑🛑🛑🛑🛑 getCourseDetail verified 🛑🛑🛑🛑🛑")
                    self.upgradeViewModel = container.resolve(
                        CourseUpgradeViewModel.self,
                        arguments: courseID, "org.openedx.app.course_upgrade_verified")
//                }
                
//                if let isEnrolled = courseDetails?.isEnrolled {
//                    self.courseDetails?.isEnrolled = isEnrolled
//                }
                
                isShowProgress = false
            } else {
                courseDetails = try await interactor.getLoadedCourseDetails(courseID: courseID)
                if let isEnrolled = courseDetails?.isEnrolled {
                    self.courseDetails?.isEnrolled = isEnrolled
                }
                isShowProgress = false
            }
        } catch let error {
            isShowProgress = false
            if error.isInternetError || error is NoCachedDataError {
                errorMessage = CoreLocalization.Error.slowOrNoInternetConnection
            } else {
                errorMessage = CoreLocalization.Error.unknownError
            }
        }
    }
    
    func courseState() -> CourseState {
        if courseDetails?.isEnrolled == false {
            if let enrollmentStart = courseDetails?.enrollmentStart, let enrollmentEnd = courseDetails?.enrollmentEnd {
                let enrollmentsRange = DateInterval(start: enrollmentStart, end: enrollmentEnd)
                if enrollmentsRange.contains(Date()) {
                    return .enrollOpen
                } else {
                    return .enrollClose
                }
            } else {
                return .enrollOpen
            }
        } else {
            return .alreadyEnrolled
        }
    }
    
    func showCourseVideo() {
        guard let youtubeURL = URL(string: courseDetails?.courseVideoURL ?? "") else { return }
        let httpsURL = youtubeURL.absoluteString.replacingOccurrences(of: "http://", with: "https://")
        guard let url = URL(string: httpsURL) else { return }
        UIApplication.shared.open(url)
    }
    
    func viewCourseClicked(courseId: String, courseName: String) {
        analytics.viewCourseClicked(courseId: courseId, courseName: courseName)
    }
    
    @MainActor
    func enrollToCourse(id: String) async {
        do {
            analytics.courseEnrollClicked(courseId: id, courseName: courseDetails?.courseTitle ?? "")
            _ = try await interactor.enrollToCourse(courseID: id)
            analytics.courseEnrollSuccess(courseId: id, courseName: courseDetails?.courseTitle ?? "")
            courseDetails?.isEnrolled = true
            print("🪀🪀🪀🪀🪀🪀 enrollToCourse 🪀🪀🪀🪀🪀🪀🪀\n \(courseDetails?.courseModes)")
            NotificationCenter.default.post(name: .onCourseEnrolled, object: id)
        } catch let error {
            if error.isInternetError || error is NoCachedDataError {
                errorMessage = CoreLocalization.Error.slowOrNoInternetConnection
            } else {
                errorMessage = CoreLocalization.Error.unknownError
            }
        }
    }
}
