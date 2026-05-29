//
//  MapoteApp.swift
//  Mapote
//
//  Created by 雷杰 on 2026/4/15.
//

import SwiftUI
import UIKit

extension Notification.Name {
    static let mapoteCloudKitRemoteChange = Notification.Name("mapote-cloudkit-remote-change")
}

final class MapoteAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        NotificationCenter.default.post(name: .mapoteCloudKitRemoteChange, object: nil)
        completionHandler(.newData)
    }
}

@main
struct MapoteApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(MapoteAppDelegate.self) private var appDelegate
    @StateObject private var store = NoteStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active || phase == .background else { return }
                    Task { await store.syncWithiCloud() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .mapoteCloudKitRemoteChange)) { _ in
                    Task { await store.syncWithiCloud() }
                }
        }
    }
}
