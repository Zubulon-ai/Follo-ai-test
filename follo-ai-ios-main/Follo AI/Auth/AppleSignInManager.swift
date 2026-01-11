//
//  AppleSignInManager.swift
//  Follo AI
//
//  Created by Henry on 10/28/25.
//

import Foundation
import AuthenticationServices
import SwiftUI

// MARK: - Models
struct AppleLoginResponse: Codable {
    let access_token: String
    let refresh_token: String
    let token_type: String
    let user: AppleUser
}

struct AppleLoginRequest: Codable {
    let authorization_code: String
    let full_name: String?
    let identity_token: String?
}

struct AppleUser: Identifiable, Codable {
    let id: Int
    let username: String
    let email: String?
    let is_active: Bool

    var idString: String { String(id) }
}

struct AppleSignInResult {
    let token: String
    let user: AppleUser?
    let isNewUser: Bool
}

// MARK: - Apple Sign In Manager
class AppleSignInManager: NSObject, ObservableObject {
    // 从 Info.plist 读取后端 API 基础 URL
    private let backendURL: String = {
        guard let url = Bundle.main.object(forInfoDictionaryKey: "BackendAPIURL") as? String else {
            fatalError("BackendAPIURL not found in Info.plist")
        }
        return url
    }()

    @Published var isLoggedIn = false
    @Published var currentUser: AppleUser?
    @Published var errorMessage: String?

    private var onCompletion: ((Result<AppleSignInResult, Error>) -> Void)?

    @MainActor
    func performSignIn(
        from windowScene: UIWindowScene,
        completion: @escaping (Result<AppleSignInResult, Error>) -> Void
    ) {
        self.onCompletion = completion

        let appleIDProvider = ASAuthorizationAppleIDProvider()
        let request = appleIDProvider.createRequest()
        request.requestedScopes = [.fullName, .email]

        // 生成nonce用于安全验证
        let nonce = UUID().uuidString
        request.nonce = nonce
        UserDefaults.standard.set(nonce, forKey: "apple_signin_nonce")

        let authorizationController = ASAuthorizationController(authorizationRequests: [request])
        authorizationController.delegate = self
        authorizationController.presentationContextProvider = self
        authorizationController.performRequests()
    }

    func signOut() {
        UserDefaults.standard.removeObject(forKey: "access_token")
        UserDefaults.standard.removeObject(forKey: "current_user")
        isLoggedIn = false
        currentUser = nil
    }

    func sendAuthorizationCodeToBackend(_ code: String, fullName: String?, identityToken: String?) async throws -> AppleSignInResult {
        let url = URL(string: "\(backendURL)/api/v1/auth/apple-login")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10  // 设置10秒超时

        var body: [String: Any] = ["authorization_code": code]
        if let fullName = fullName {
            body["full_name"] = fullName
        }
        if let identityToken = identityToken {
            body["identity_token"] = identityToken
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        // 检查响应状态
        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 401 {
                throw NSError(domain: "AppleSignIn", code: 401, userInfo: [NSLocalizedDescriptionKey: "登录失败，请重试"])
            } else if httpResponse.statusCode == 400 {
                let errorData = try? JSONDecoder().decode([String: String].self, from: data)
                let errorMsg = errorData?["detail"] ?? "请求参数错误"
                throw NSError(domain: "AppleSignIn", code: 400, userInfo: [NSLocalizedDescriptionKey: errorMsg])
            } else if httpResponse.statusCode >= 400 {
                throw NSError(domain: "AppleSignIn", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "服务器错误"])
            }
        }

        let loginResponse = try JSONDecoder().decode(AppleLoginResponse.self, from: data)

        // 保存token到Keychain
        let keychain = KeychainService.shared
        keychain.setAccessToken(loginResponse.access_token)
        keychain.setRefreshToken(loginResponse.refresh_token)

        // 保存用户信息到UserDefaults（向后兼容）
        if let userData = try? JSONEncoder().encode(loginResponse.user) {
            UserDefaults.standard.set(userData, forKey: "current_user")
        }

        return AppleSignInResult(
            token: loginResponse.access_token,
            user: loginResponse.user,
            isNewUser: false
        )
    }

    // 直接用授权结果完成登录（避免重复弹出 Apple 密码框）
    func completeSignIn(with credential: ASAuthorizationAppleIDCredential, completion: @escaping (Result<AppleSignInResult, Error>) -> Void) {
        Task { @MainActor in
            do {
                guard let authorizationCode = credential.authorizationCode,
                      let codeString = String(data: authorizationCode, encoding: .utf8) else {
                    throw NSError(domain: "AppleSignIn", code: -1, userInfo: [NSLocalizedDescriptionKey: "获取授权码失败"])
                }

                // 提取 fullName（包含 givenName 和 familyName）
                var fullNameString: String? = nil
                if let fullName = credential.fullName {
                    let formatter = PersonNameComponentsFormatter()
                    fullNameString = formatter.string(from: fullName)
                    print("🍎 提取到Apple fullName: \(fullNameString!)")
                } else {
                    print("⚠️ 没有获取到Apple fullName")
                }

                var identityTokenString: String? = nil
                if let idTokenData = credential.identityToken,
                   let idToken = String(data: idTokenData, encoding: .utf8) {
                    identityTokenString = idToken
                }

                let result = try await self.sendAuthorizationCodeToBackend(codeString, fullName: fullNameString, identityToken: identityTokenString)
                self.isLoggedIn = true
                self.currentUser = result.user
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
        }
    }

    @MainActor
    func loadSavedUser() {
        if let token = UserDefaults.standard.string(forKey: "access_token"),
           let userData = UserDefaults.standard.data(forKey: "current_user"),
           let user = try? JSONDecoder().decode(AppleUser.self, from: userData) {
            isLoggedIn = true
            currentUser = user
        }
    }
}

// MARK: - ASAuthorizationControllerDelegate
extension AppleSignInManager: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            do {
            guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let authorizationCode = appleIDCredential.authorizationCode,
                let codeString = String(data: authorizationCode, encoding: .utf8) else {
                    throw NSError(domain: "AppleSignIn", code: -1, userInfo: [NSLocalizedDescriptionKey: "获取授权码失败"])
                }

            // 提取 fullName
            var fullNameString: String? = nil
            if let fullName = appleIDCredential.fullName {
                let formatter = PersonNameComponentsFormatter()
                fullNameString = formatter.string(from: fullName)
                print("🍎 提取到Apple fullName: \(fullNameString!)")
            } else {
                print("⚠️ 没有获取到Apple fullName")
            }

            var identityTokenString: String? = nil
            if let idTokenData = appleIDCredential.identityToken,
             let idToken = String(data: idTokenData, encoding: .utf8) {
              identityTokenString = idToken
            }

            let result = try await sendAuthorizationCodeToBackend(codeString, fullName: fullNameString, identityToken: identityTokenString)
                isLoggedIn = true
                currentUser = result.user

                onCompletion?(.success(result))
            } catch {
                errorMessage = error.localizedDescription
                onCompletion?(.failure(error))
            }
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let nsError = error as NSError
        if nsError.code != ASAuthorizationError.canceled.rawValue {
            errorMessage = error.localizedDescription
            onCompletion?(.failure(error))
        }
    }
}

// MARK: - ASAuthorizationControllerPresentationContextProviding
extension AppleSignInManager: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else {
            return UIWindow()
        }
        return window
    }
}
