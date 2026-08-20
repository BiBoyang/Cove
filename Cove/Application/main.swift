import AppKit

// Manual app wiring: no storyboard, no @main attribute.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
