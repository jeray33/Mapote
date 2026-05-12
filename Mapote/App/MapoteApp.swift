//
//  MapoteApp.swift
//  Mapote
//
//  Created by 雷杰 on 2026/4/15.
//

import SwiftUI

@main
struct MapoteApp: App {
    @StateObject private var store = NoteStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}
