import AppKit
import Skreen2GoCore

// Top-level code in `main.swift` is nonisolated but always runs on the main thread,
// which is what lets the main-actor delegate be constructed here.
let application = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
