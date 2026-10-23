import Cocoa

let delegate = MainActor.assumeIsolated { AppDelegate() }
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
