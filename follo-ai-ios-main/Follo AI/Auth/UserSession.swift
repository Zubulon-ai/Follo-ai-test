//
//  UserSession.swift
//  Follo AI
//
//  Created by Henry on 10/28/25.
//

import Foundation
import SwiftUI
import AuthenticationServices

class UserSession: ObservableObject {
    @Published var isLoggedIn = false
    @Published var currentUser: AppleUser?
    @Published var isInitialized = false  // 新增：标记是否已完成初始化
    @Published var showError = false  // 新增：是否显示错误弹窗
    @Published var errorMessage = ""  // 新增：错误信息

    private let appleSignInManager = AppleSignInManager()
    private let keychainService = KeychainService.shared
    private let backendService = BackendAPIService()

    /// 事件同步管理器
    let eventSyncManager = EventSyncManager()

    init() {
        Task { @MainActor in
            await checkAuthStatus()
            isInitialized = true  // 标记初始化完成
        }
    }

    /// 检查认证状态 - 在App启动时调用
    @MainActor
    func checkAuthStatus() async {
        print("🔄 开始检查认证状态...")

        // 从Keychain中获取Token
        let accessToken = keychainService.getAccessToken()
        let refreshToken = keychainService.getRefreshToken()

        print("🔑 Keychain中的Token: accessToken=\(accessToken != nil), refreshToken=\(refreshToken != nil)")

        guard let accessToken = accessToken,
              let refreshToken = refreshToken else {
            // 没有Token，显示登录界面
            print("❌ 没有找到Token，显示登录界面")
            isLoggedIn = false
            return  // 不再尝试无效的同步
        }

        // 尝试使用accessToken获取用户信息
        print("🔍 尝试获取用户信息...")
        do {
            let user = try await backendService.getCurrentUser()
            currentUser = user
            isLoggedIn = true
            print("✅ 已登录用户: \(user.email ?? "No email")")
            print("   用户名: \(user.username)")

            // 🚀 鉴权成功，立即进入主页，同步在后台进行
            // 不等待同步完成，直接返回让用户进入主页
            Task {
                print("🔄 后台开始同步事件...")
                await eventSyncManager.authenticateAndSync()
            }

        } catch BackendAPIError.unauthorized {
            // accessToken已过期，尝试刷新
            print("⚠️ accessToken已过期，尝试刷新...")
            await refreshTokens()
        } catch let error as URLError {
            // 网络错误或超时
            print("❌ 网络错误: \(error.localizedDescription)")
            if error.code == .timedOut {
                errorMessage = "网络连接出现问题，请稍后再试"
            } else {
                errorMessage = "网络连接失败，请检查网络设置"
            }
            showError = true
            isLoggedIn = false
        } catch {
            print("❌ 获取用户信息失败: \(error.localizedDescription)")
            errorMessage = "获取用户信息失败，请重试"
            showError = true
            isLoggedIn = false
        }
    }

    /// 刷新Token
    private func refreshTokens() async {
        guard let refreshToken = keychainService.getRefreshToken() else {
            print("❌ 没有refreshToken，无法刷新")
            await signOut()
            return
        }

        do {
            let tokenResponse = try await backendService.refreshToken(refreshToken: refreshToken)
            // 保存新的Token
            keychainService.setAccessToken(tokenResponse.access_token)
            keychainService.setRefreshToken(tokenResponse.refresh_token)

            // 重新获取用户信息
            let user = try await backendService.getCurrentUser()
            currentUser = user
            isLoggedIn = true
            print("✅ Token刷新成功")

            // 🚀 Token刷新成功，立即返回，同步在后台进行
            Task {
                print("🔄 后台开始同步事件...")
                await eventSyncManager.authenticateAndSync()
            }

        } catch let error as URLError {
            // 网络错误或超时
            print("❌ 网络错误: \(error.localizedDescription)")
            if error.code == .timedOut {
                errorMessage = "网络连接出现问题，请稍后再试"
            } else {
                errorMessage = "网络连接失败，请检查网络设置"
            }
            showError = true
            await signOut()
        } catch {
            print("❌ Token刷新失败: \(error.localizedDescription)")
            await signOut()
        }
    }

    @MainActor
    func signIn(from windowScene: UIWindowScene, completion: @escaping (Result<AppleSignInResult, Error>) -> Void) {
        appleSignInManager.performSignIn(from: windowScene) { [weak self] result in
            switch result {
            case .success(let signInResult):
                // 更新登录状态
                self?.isLoggedIn = true
                self?.currentUser = signInResult.user

                // 🚀 登录成功，立即返回，同步在后台进行
                Task {
                    print("📅 登录成功，后台开始同步...")
                    await self?.eventSyncManager.authenticateAndSync()
                }

                completion(.success(signInResult))

            case .failure(let error):
                print("登录失败: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }

    // 使用系统 SignInWithAppleButton 的授权结果直接完成登录，避免重复触发授权流程
    @MainActor
    func signIn(with authorization: ASAuthorization, completion: @escaping (Result<AppleSignInResult, Error>) -> Void) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            completion(.failure(NSError(domain: "AppleSignIn", code: -2, userInfo: [NSLocalizedDescriptionKey: "授权信息无效"])))
            return
        }

        appleSignInManager.completeSignIn(with: credential) { [weak self] result in
            switch result {
            case .success(let signInResult):
                self?.isLoggedIn = true
                self?.currentUser = signInResult.user
                self?.isInitialized = true  // 确保初始化完成

                print("🍎 Apple登录成功")
                print("   用户: \(signInResult.user?.email ?? "No email")")
                print("   Token已保存到Keychain")

                // 🚀 登录成功，立即返回，同步在后台进行
                Task {
                    print("📅 登录成功，后台开始同步...")
                    await self?.eventSyncManager.authenticateAndSync()
                }

                completion(.success(signInResult))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    @MainActor
    func signOut() async {
        appleSignInManager.signOut()
        keychainService.clearTokens()
        isLoggedIn = false
        currentUser = nil
        isInitialized = true  // 保持为 true，避免再次显示加载界面

        // 🔄 停止事件同步
        print("📅 已退出登录，停止事件同步")

        print("已退出登录")
    }
}
