//
//  AppDelegate.swift
//  Follo AI
//
//  App delegate for handling push notifications
//

import UIKit
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Register for remote notifications
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        ) { granted, error in
            if granted {
                DispatchQueue.main.async {
                    application.registerForRemoteNotifications()
                }
            }
        }

        // Check if user is already logged in and register device
        ReminderService.shared.registerCurrentDevice()

        // Start Token Auto-Refresh
        TokenRefreshManager.shared.startAutoRefresh()

        // Start Trigger Manager (iOS 17+)
        if #available(iOS 17.0, *) {
            TriggerManager.shared.startMonitoring()
        }

        return true
    }

    // Handle successful registration for remote notifications
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("Device Token: \(tokenString)")

        // Register device token with backend
        ReminderService.shared.registerDevice(deviceToken: tokenString)
    }

    // Handle failed registration for remote notifications
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("Failed to register for remote notifications: \(error)")
    }

    // Handle receiving remote notification while app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let content = notification.request.content
        let userInfo = content.userInfo

        // Store full message for ChatView
        if let fullMessage = userInfo["full_message"] as? [String: String] {
            ChatMessageStore.shared.storeFullMessage(fullMessage)
        }

        // Show notification even in foreground
        completionHandler([.banner, .sound, .badge])
    }

    // Handle notification tap
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        // Handle notification tap
        if let fullMessage = userInfo["full_message"] as? [String: String] {
            ChatMessageStore.shared.storeFullMessage(fullMessage)
            NotificationCenter.default.post(name: .notificationTapped, object: fullMessage)
        }

        completionHandler()
    }

    // Handle background remote notification with completion handler
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        print("📱 [AppDelegate] Received remote notification")
        print("📱 [AppDelegate] Application state: \(application.applicationState.rawValue)")
        print("📱 [AppDelegate] User Info: \(userInfo)")
        
        // Check if this is a silent push notification
        if let aps = userInfo["aps"] as? [String: Any] {
            print("📱 [AppDelegate] APS dictionary: \(aps)")
            
            // Extract content-available value
            let contentAvailable = aps["content-available"] as? Int
            
            if let contentAvailable = contentAvailable {
                print("📱 [AppDelegate] Content-available: \(contentAvailable)")
            } else {
                print("⚠️ [AppDelegate] No content-available field found")
            }
            
            // Check if this is a silent push (content-available == 1)
            if contentAvailable == 1 {
                print("✅ [AppDelegate] This is a silent push notification")
                
                if let eventId = userInfo["event_id"] as? String {
                    print("✅ [AppDelegate] Event ID: \(eventId)")
                    
                    // Collect context and send to backend
                    ReminderService.shared.handleSilentPush(eventId: eventId) { success in
                        print("📱 [AppDelegate] Context collection completed: \(success)")
                        if success {
                            completionHandler(.newData)
                        } else {
                            completionHandler(.failed)
                        }
                    }
                } else {
                    print("❌ [AppDelegate] No event_id found in userInfo")
                    completionHandler(.noData)
                }
            } else {
                print("📱 [AppDelegate] Not a silent push (content-available != 1)")
                completionHandler(.noData)
            }
        } else {
            print("❌ [AppDelegate] No aps dictionary found")
            completionHandler(.noData)
        }
    }
}
