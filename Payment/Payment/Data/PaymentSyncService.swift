//
//  PaymentSyncService.swift
//  Payment
//
//  Created by Rawan Matar on 15/04/2026.
//

import Foundation
import BackgroundTasks
#if canImport(UIKit)
import UIKit
#endif
import Core

// MARK: - PaymentSyncService

public final class PaymentSyncService {

    // MARK: Configuration

    public static let bgTaskIdentifier = "com.openedx.payment.sync"

    // MARK: Dependencies

    private let repository: PaymentRepositoryProtocol
    private let store: PendingTransactionStore
    private let onSyncResult: ((SyncResult) -> Void)?

    // MARK: Internal state

    private var foregroundTimer: Task<Void, Never>?
    private var notificationObservers: [NSObjectProtocol] = []
    private let foregroundPollingInterval: TimeInterval = 60

    // MARK: Init

    /// - Parameter onSyncResult: Called on the main actor for each completed
    ///   retry, so the ViewModel can react (e.g. show success toast).
    public init(
        repository: PaymentRepositoryProtocol,
        store: PendingTransactionStore = .shared,
        onSyncResult: ((SyncResult) -> Void)? = nil
    ) {
        self.repository = repository
        self.store = store
        self.onSyncResult = onSyncResult
    }

    // MARK: - Lifecycle

    /// Call once from `AppDelegate.application(_:didFinishLaunchingWithOptions:)`.
    /// Registers the BG task handler and starts all retry triggers.
    public func start() {
        registerBGTask()
        startForegroundTimer()
        observeAppLifecycleNotifications()

        // Immediate check on startup — catches transactions that were
        // pending when the app was last terminated.
        Task {
            await runRetry(source: "app_launch")
        }
    }

    /// Call from `AppDelegate.applicationWillTerminate` or `SceneDelegate` teardown.
    public func stop() {
        foregroundTimer?.cancel()
        foregroundTimer = nil
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        notificationObservers = []
    }

    // MARK: - BGTaskScheduler

    /// Register the processing task handler. Must be called before the first
    /// `applicationDidFinishLaunching` returns (iOS requirement).
    public func registerBGTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.bgTaskIdentifier,
            using: nil   // runs on a background queue provided by the system
        ) { [weak self] task in
            guard let self, let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleBGTask(processingTask)
        }
    }

    /// Schedule a one-off BG processing task. Call after writing a new pending
    /// transaction to the store.
    public func scheduleBGTaskIfNeeded() {
        guard store.hasAny else { return }

        let request = BGProcessingTaskRequest(identifier: Self.bgTaskIdentifier)
        // Earliest fire time = next due retry (or 5 minutes from now).
        let nextDue = store.allPending()
            .map { $0.nextRetryDate }
            .min() ?? Date().addingTimeInterval(300)
        request.earliestBeginDate = max(nextDue, Date().addingTimeInterval(60))
        // Require network connectivity — we're doing network work.
        request.requiresNetworkConnectivity = true
        // Don't require external power unless retries have been failing for a
        // long time and we're doing a catch-all overnight sync.
        request.requiresExternalPower = false

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch BGTaskScheduler.Error.unavailable {
            // Simulator, or background modes not enabled — silently ignore.
            ()
        } catch {
            // Log but don't crash — retry via foreground timer as fallback.
            print("[PaymentSyncService] Failed to schedule BG task: \(error)")
        }
    }

    // MARK: - Private: BG task handler

    private func handleBGTask(_ task: BGProcessingTask) {
        // Re-schedule the next BG task immediately in case we're killed.
        scheduleBGTaskIfNeeded()

        let syncTask = Task {
            let results = await repository.retryPendingTransactions()
            await notifyResults(results)
            task.setTaskCompleted(success: true)
            // If transactions are still pending, the next BGTask will handle them.
        }

        // iOS gives us a time limit — if we're about to be killed, cancel work.
        task.expirationHandler = {
            syncTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    // MARK: - Private: foreground timer

    private func startForegroundTimer() {
        foregroundTimer?.cancel()
        foregroundTimer = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.foregroundPollingInterval ?? 60))
                guard !Task.isCancelled else { break }
                await self?.runRetry(source: "foreground_timer")
            }
        }
    }

    // MARK: - Private: app lifecycle notifications

    private func observeAppLifecycleNotifications() {
        #if canImport(UIKit)
        let foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.runRetry(source: "foreground_notification") }
        }
        notificationObservers.append(foregroundObserver)
        #endif
    }

    // MARK: - Private: shared retry runner

    @MainActor
    private func runRetry(source: String) async {
        guard store.hasAny else { return }
        let results = await repository.retryPendingTransactions()
        await notifyResults(results)

        // Re-schedule BG task after each foreground retry in case there
        // are still-pending records with future retry dates.
        if store.hasAny {
            scheduleBGTaskIfNeeded()
        }
    }

    @MainActor
    private func notifyResults(_ results: [SyncResult]) async {
        for result in results {
            onSyncResult?(result)
        }
    }
}

// MARK: - AppDelegate integration snippet

/*
 In AppDelegate.swift:

   private let paymentSyncService = Container.shared.resolve(PaymentSyncService.self)!

   func application(
       _ application: UIApplication,
       didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
   ) -> Bool {
       // IMPORTANT: BGTask handler registration must happen before this
       // function returns. PaymentSyncService.start() calls registerBGTask().
       paymentSyncService.start()
       return true
   }

   func applicationWillTerminate(_ application: UIApplication) {
       paymentSyncService.stop()
   }
*/

// MARK: - ViewModel integration for pending state

/*
 In CourseUpgradeViewModel, after a syncPurchase call returns .pending:

   case .pending(let txID):
        Update state to show the "sync in progress" banner
       purchaseState = .syncing(transactionID: txID)

        Listen for the PaymentSyncService callback
       NotificationCenter.default.publisher(
           for: .paymentSyncDidComplete
       )
       .receive(on: DispatchQueue.main)
       .sink { [weak self] notification in
           if let result = notification.object as? SyncResult,
              case .enrolled(let courseID) = result {
               self?.purchaseState = .success(courseID: courseID, transactionID: txID)
           }
       }
       .store(in: &cancellables)
*/

public extension Notification.Name {
    static let paymentSyncDidComplete = Notification.Name("com.openedx.payment.syncDidComplete")
}
