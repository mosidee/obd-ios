//
//  OBDELM327ConnectorApp.swift
//  OBD ELM327 Connector
//

import SwiftUI
import UIKit

@main
struct OBDELM327ConnectorApp: App {
    init() {
        let keepAwake = UserDefaults.standard.object(forKey: "keepScreenAwake") as? Bool ?? true
        UIApplication.shared.isIdleTimerDisabled = keepAwake
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
