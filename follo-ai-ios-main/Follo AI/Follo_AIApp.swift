//
//  Follo_AIApp.swift
//  Follo AI
//
//  Created by 邹昕恺 on 9/10/25.
//

import SwiftUI
import EventKit

@main
struct Follo_AIApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var calendarProvider = CalendarEventProvider()
    @StateObject private var userSession = UserSession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(calendarProvider)
                .environmentObject(userSession)
        }
    }
}
