//
//  LoginView.swift
//  Follo AI
//
//  Created by Henry on 10/28/25.
//

import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @EnvironmentObject var userSession: UserSession
    @State private var isLoading = false
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            // Logo/标题
            VStack(spacing: 16) {
                Image(systemName: "brain")
                    .font(.system(size: 80))
                    .foregroundColor(.blue)

                Text("Follo AI")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("你的智能助手")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Apple Sign In 按钮
            SignInWithAppleButton(
                onRequest: { request in
                    request.requestedScopes = [.fullName, .email]
                    // 生成并设置 nonce（可选，建议）
                    let nonce = UUID().uuidString
                    request.nonce = nonce
                    UserDefaults.standard.set(nonce, forKey: "apple_signin_nonce")
                },
                onCompletion: { result in
                    Task {
                        await handleAppleSignIn(result: result)
                    }
                }
            )
            .signInWithAppleButtonStyle(.black)
            .frame(height: 50)
            .cornerRadius(8)
            .padding(.horizontal, 24)

            if isLoading {
                ProgressView()
                    .padding()
            }

            Spacer()
        }
        .padding()
        .alert("错误", isPresented: $showError) {
            Button("确定", role: .cancel) {
                showError = false
            }
        } message: {
            Text(errorMessage)
        }
    }

    private func handleAppleSignIn(result: Result<ASAuthorization, Error>) async {
        isLoading = true
        defer { isLoading = false }

        switch result {
        case .success(let authorization):
            await withCheckedContinuation { continuation in
                userSession.signIn(with: authorization) { result in
                    switch result {
                    case .success(let signInResult):
                        print("✅ 登录成功")
                        print("   用户: \(signInResult.user?.email ?? "No email")")
                        print("   Token: \(signInResult.token.prefix(20))...")
                        continuation.resume()
                    case .failure(let error):
                        print("❌ 登录失败: \(error.localizedDescription)")
                        // 检查是否是超时错误
                        if let urlError = error as? URLError, urlError.code == .timedOut {
                            self.errorMessage = "网络连接出现问题，请稍后再试"
                        } else {
                            self.errorMessage = "登录失败，请重试"
                        }
                        self.showError = true
                        continuation.resume()
                    }
                }
            }
        case .failure(let error):
            print("❌ 授权失败: \(error.localizedDescription)")
            // 检查是否是超时错误
            if let urlError = error as? URLError, urlError.code == .timedOut {
                errorMessage = "网络连接出现问题，请稍后再试"
            } else {
                errorMessage = "授权失败，请重试"
            }
            showError = true
        }
    }

    // 不再需要单独获取 windowScene 来触发二次授权
}

#Preview {
    LoginView()
}
