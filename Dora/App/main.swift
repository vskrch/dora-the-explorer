import AppKit

// Explicit AppKit bootstrap: assign the delegate, then run the event loop.
// See AppDelegate for why this isn't using the `@main` codegen.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
