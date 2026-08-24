import AppKit

// Manual app wiring: no storyboard, no @main attribute.
let application = NSApplication.shared
// The UI is designed dark-only (Infuse-style); lock it before any window
// appears so light mode never renders an untested combination.
application.appearance = NSAppearance(named: .darkAqua)
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
