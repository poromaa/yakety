import SwiftUI
import AppKit

// MARK: - Shared Modal Dialog Utilities

// MARK: - Protocol for Dialog States

protocol ModalDialogState: ObservableObject {
    associatedtype ResultType
    var isCompleted: Bool { get set }
    var result: ResultType { get }
    func reset()
}

// MARK: - Generic Modal Dialog Function

@_optimize(none)
func runModalDialog<T: View, StateType: ModalDialogState>(
    content: T,
    state: StateType,
    windowSize: NSSize = NSSize(width: 400, height: 200),
    windowTitle: String = ""
) -> StateType.ResultType {
    // Initialize NSApp if not already done (for CFRunLoop compatibility)
    if NSApp.delegate == nil {
        _ = NSApplication.shared
    }
    
    // Activate the application and bring to front
    NSApp.activate(ignoringOtherApps: true)
    
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: windowSize),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    
    if !windowTitle.isEmpty {
        window.title = windowTitle
    }
    
    window.center()
    window.isReleasedWhenClosed = false
    window.level = .floating  // Ensure window appears above other apps
    
    // Reset state
    state.reset()
    
    let contentView = content
    window.contentView = NSHostingView(rootView: contentView)
    
    // Make window key and bring to front with proper activation
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    NSApp.activate(ignoringOtherApps: true)
    
    // Modal loop compatible with both CFRunLoop and NSApp
    while !state.isCompleted {
        if let event = NSApp.nextEvent(matching: .any, until: Date.distantFuture, inMode: RunLoop.Mode.defaultRunLoopMode, dequeue: true) {
            NSApp.sendEvent(event)
        }
    }
    
    window.close()
    return state.result
}

// MARK: - Shared App Icon Utility

func loadAppIcon() -> NSImage? {
    // For CLI/test executables, try to find the icon next to the executable first
    if let executablePath = Bundle.main.executablePath {
        let executableDir = (executablePath as NSString).deletingLastPathComponent
        let iconPath = (executableDir as NSString).appendingPathComponent("menubar.png")
        
        if FileManager.default.fileExists(atPath: iconPath) {
            let appIcon = NSImage(contentsOfFile: iconPath)
            return appIcon
        }
    }
    
    // For .app bundles, try the app's actual icon
    let appIcon = NSApp.applicationIconImage
    if appIcon != nil && !isGenericIcon(appIcon!) {
        return appIcon
    }
    
    // Try bundle resources (for .app)
    if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns") {
        let bundleIcon = NSImage(contentsOfFile: iconPath)
        return bundleIcon
    }
    
    // No suitable icon found
    return nil
}

private func isGenericIcon(_ image: NSImage) -> Bool {
    // Check if this is a generic system icon by looking at common generic icon names
    let representations = image.representations
    return representations.isEmpty || image.name()?.rawValue.contains("Generic") == true
}

// Note: Dialog state extensions will be defined in each dialog file to avoid circular dependencies