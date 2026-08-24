import Foundation
import AppKit
import SwiftUI

if CLI.shouldRun {
    CLI.run()
}

// GUI mode: run as a regular app even when launched from a bare executable.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    objc_setAssociatedObject(app, "appDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.setActivationPolicy(.regular)
    app.run()
}
