//
//  ContentView.swift
//  Follo AI
//
//  Created by 邹昕恺 on 9/10/25.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var userSession: UserSession

    var body: some View {
        Group {
            if !userSession.isInitialized {
                // 初始化期间显示加载界面
                VStack {
                    ProgressView("加载中...")
                        .progressViewStyle(CircularProgressViewStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if userSession.isLoggedIn {
                MainAppView()
            } else {
                LoginView()
                    .environmentObject(userSession)
            }
        }
        .alert("错误", isPresented: $userSession.showError) {
            Button("确定", role: .cancel) {
                userSession.showError = false
            }
        } message: {
            Text(userSession.errorMessage)
        }
    }
}

// MARK: - 主应用视图
struct MainAppView: View {
    @EnvironmentObject var userSession: UserSession

    var body: some View {
        TabView {
            NavigationStack { StatusView() }
                .tabItem {
                    Image(systemName: "person.crop.circle")
                    Text("状态")
                }
            NavigationStack { VoiceChatView(embedInNavigation: false) }
                .tabItem {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text("Follo")
                }
            NavigationStack { QuickCreateView() }
                .tabItem {
                    Image(systemName: "waveform")
                    Text("快速创建")
                }
            NavigationStack { CalendarScreen() }
                .tabItem {
                    Image(systemName: "calendar")
                    Text("日程")
                }
            NavigationStack { AssistantsView() }
                .tabItem {
                    Image(systemName: "person.3")
                    Text("协作")
                }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        // 显示用户信息
                    } label: {
                        Label("用户信息", systemImage: "person.circle")
                    }

                    Button(role: .destructive) {
                        Task {
                            await userSession.signOut()
                        }
                    } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .onAppear {
            // 设置Tab Bar的外观
            let appearance = UITabBarAppearance()
            appearance.configureWithOpaqueBackground()
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }
}

#Preview {
    ContentView()
}
