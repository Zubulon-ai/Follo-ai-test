//
//  ReminderService.swift
//  Follo AI
//
//  Service for handling reminder notifications and context collection
//

import Foundation
import UIKit

class ReminderService {
    static let shared = ReminderService()

    private let baseURL: String
    private let deviceId = "default-device"  // TODO: Get from device

    private init() {
        // 从 Info.plist 读取 BackendAPIURL
        if let infoDict = Bundle.main.infoDictionary,
           let url = infoDict["BackendAPIURL"] as? String {
            self.baseURL = url
        } else {
            // 如果没有配置，使用默认值
            self.baseURL = "http://localhost:8000"
        }
        print("Backend API URL: \(baseURL)")
    }

    // Register device token with backend
    func registerDevice(deviceToken: String) {
        // Check if we have auth token
        guard let authToken = getAuthToken() else {
            // No auth token, store device token for later registration
            print("No auth token found, caching device token for later registration")
            storeDeviceToken(deviceToken)
            return
        }

        // We have auth token, register immediately
        _registerDeviceWithAuth(deviceToken: deviceToken, authToken: authToken)
    }

    // Manually register current device (e.g., on app launch or after login)
    func registerCurrentDevice() {
        print("Manually registering current device...")

        // Check if user is logged in
        guard getAuthToken() != nil else {
            print("No auth token, cannot register device")
            return
        }

        // Check notification authorization status
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .authorized ||
               settings.authorizationStatus == .provisional {
                print("Push authorized, requesting device token...")
                DispatchQueue.main.async {
                    // This will trigger didRegisterForRemoteNotificationsWithDeviceToken
                    // which will call registerDevice() with the current token
                    UIApplication.shared.registerForRemoteNotifications()
                }
            } else {
                print("Push not authorized, cannot register device")
            }
        }
    }

    // Internal method to register device with auth token
    private func _registerDeviceWithAuth(deviceToken: String, authToken: String) {
        let urlString = "\(baseURL)/devices/register"
        guard let url = URL(string: urlString) else {
            print("Invalid URL for device registration: \(urlString)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "device_token": deviceToken,
            "device_type": "ios"
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("Error registering device: \(error)")
                return
            }

            if let data = data,
               let responseString = String(data: data, encoding: .utf8) {
                print("Device registration response: \(responseString)")

                // Check if registration was successful
                if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let success = json["success"] as? Bool, success {
                    // Registration successful, clear cached token
                    self.clearCachedDeviceToken()
                }
            }
        }.resume()
    }

    // Store device token for later registration
    private func storeDeviceToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: "cached_device_token")
        print("Device token cached for later registration")
    }

    // Get cached device token
    private func getCachedDeviceToken() -> String? {
        return UserDefaults.standard.string(forKey: "cached_device_token")
    }

    // Clear cached device token
    private func clearCachedDeviceToken() {
        UserDefaults.standard.removeObject(forKey: "cached_device_token")
        print("Cached device token cleared")
    }

    // Get stored auth token (from Keychain)
    // Note: Token is stored in KeychainService, not UserDefaults
    func getAuthToken() -> String? {
        return KeychainService.shared.getAccessToken()
    }

    // Store auth token (to Keychain)
    // Note: Token is stored in KeychainService, not UserDefaults
    func storeAuthToken(_ token: String) {
        KeychainService.shared.setAccessToken(token)
        print("✅ Auth token stored to Keychain")
    }

    // Login with email/password (simplified)
    func login(email: String, password: String, completion: @escaping (Bool) -> Void) {
        let urlString = "\(baseURL)/api/v1/auth/login"
        guard let url = URL(string: urlString) else {
            print("Invalid URL for login")
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // OAuth2PasswordRequestForm uses 'username' field for email
        let body = "username=\(email)&password=\(password)"
        request.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("Login error: \(error)")
                completion(false)
                return
            }

            guard let data = data else {
                print("No data received from login")
                completion(false)
                return
            }

            // Try to parse the response
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let accessToken = json["access_token"] as? String {
                    self.storeAuthToken(accessToken)
                    print("Login successful, token stored")

                    // Check if we have a cached device token to register
                    if let cachedToken = self.getCachedDeviceToken() {
                        print("Found cached device token, registering now")
                        self._registerDeviceWithAuth(deviceToken: cachedToken, authToken: accessToken)
                    }

                    // Also trigger device registration to get current token
                    self.registerCurrentDevice()

                    completion(true)
                } else {
                    print("Invalid login response")
                    completion(false)
                }
            } catch {
                print("Error parsing login response: \(error)")
                completion(false)
            }
        }.resume()
    }

    // Handle silent push notification
    func handleSilentPush(eventId: String, completion: @escaping (Bool) -> Void) {
        print("🔔 [ReminderService] Starting silent push handler")
        print("🔔 [ReminderService] Event ID: \(eventId)")

        // Collect context signals
        collectContextSignals { signals in
            print("🔔 [ReminderService] Collected \(signals.count) context signals")
            
            guard !signals.isEmpty else {
                print("❌ [ReminderService] No context signals collected")
                completion(false)
                return
            }

            // Print collected signals
            for signal in signals {
                print("📊 [ReminderService] Signal: \(signal.type) = \(signal.value)")
            }

            // Send context to backend
            self.sendContextToBackend(eventId: eventId, signals: signals) { success in
                print("🔔 [ReminderService] Context upload result: \(success)")
                completion(success)
            }
        }
    }

    // Collect context signals using ContextCollector
    private func collectContextSignals(completion: @escaping ([ContextSignal]) -> Void) {
        print("📱 [ReminderService] Starting context collection...")
        
        // Use existing ContextCollector (async call)
        Task {
            do {
                print("📱 [ReminderService] Calling ContextCollector.collectContext()")
                
                // Call async method
                let signals = await ContextCollector.shared.collectContext()
                
                print("📱 [ReminderService] ContextCollector returned \(signals.count) signals")

                // Convert SignalDescription to ContextSignal
                let contextSignals = signals.map { signal in
                    ContextSignal(type: signal.signal, value: String(describing: signal.value))
                }
                
                print("📱 [ReminderService] Converted to \(contextSignals.count) ContextSignals")
                completion(contextSignals)
            } catch {
                print("❌ [ReminderService] Failed to collect context: \(error)")
                completion([])
            }
        }
    }

    // Send context signals to backend
    private func sendContextToBackend(
        eventId: String,
        signals: [ContextSignal],
        completion: @escaping (Bool) -> Void
    ) {
        print("🌐 [ReminderService] Preparing to send context to backend")
        print("🌐 [ReminderService] Event ID: \(eventId)")
        print("🌐 [ReminderService] Number of signals: \(signals.count)")
        
        // 使用正确的 API 路径：/reminders/context
        let urlString = "\(baseURL)/reminders/context"
        print("🌐 [ReminderService] Request URL: \(urlString)")
        
        guard let url = URL(string: urlString) else {
            print("❌ [ReminderService] Invalid URL for context upload: \(urlString)")
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // 添加 Authorization header
        if let authToken = getAuthToken() {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            print("✅ [ReminderService] Authorization token added")
        } else {
            print("⚠️ [ReminderService] Warning: No auth token found. Context upload may fail.")
        }

        let body: [String: Any] = [
            "event_id": eventId,
            "context_signals": signals.map { signal in
                [
                    "type": signal.type,
                    "value": signal.value
                ]
            }
        ]
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: body, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            print("📤 [ReminderService] Request body: \(jsonString)")
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        print("🌐 [ReminderService] Sending request...")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("❌ [ReminderService] Error sending context to backend: \(error)")
                completion(false)
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                print("🌐 [ReminderService] Response status code: \(httpResponse.statusCode)")
            }

            if let data = data,
               let responseString = String(data: data, encoding: .utf8) {
                print("✅ [ReminderService] Context upload response: \(responseString)")
                completion(true)
            } else {
                print("⚠️ [ReminderService] No response data received")
                completion(false)
            }
        }.resume()
    }
}

// Data model for context signals
struct ContextSignal: Codable {
    let type: String
    let value: String

    init(type: String, value: String) {
        self.type = type
        self.value = value
    }
}

// Chat message store for notification content
class ChatMessageStore {
    static let shared = ChatMessageStore()

    private var fullMessage: [String: String]?

    private init() {}

    func storeFullMessage(_ message: [String: String]) {
        fullMessage = message
    }

    func getFullMessage() -> [String: String]? {
        return fullMessage
    }

    func clear() {
        fullMessage = nil
    }
}

// Notification name for notification tap
extension Notification.Name {
    static let notificationTapped = Notification.Name("notificationTapped")
}
