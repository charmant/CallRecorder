import AppKit
import SwiftUI

/// For design screenshots: `--preview <state>` applies the state and shows the same
/// MenuView in a floating window on system glass (the MenuBarExtra window can't be opened
/// programmatically: it responds neither to performClick nor to synthetic mouse events). The window
/// number is written to the diagnostics log, then `screencapture -l <number>`. Recording and permissions are left alone.
enum PreviewHarness {
    static let state: String? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--preview"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }()

    /// `history…` states open the history window instead of the panel.
    static var opensHistory: Bool { state?.hasPrefix("history") == true }

    @MainActor private static var panel: NSPanel?

    @MainActor
    static func show(model: AppModel, log: DiagnosticLog) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if !opensHistory { showPanel(model: model) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let windows = NSApp.windows.filter { $0.isVisible && !$0.className.contains("StatusBar") }
                log.write("preview \(state ?? "?"): windows "
                    + windows.map { "\($0.windowNumber) \(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: ", "))
                if let directory = outputDirectory {
                    for (index, window) in windows.enumerated() {
                        snapshot(window, to: directory.appending(path: "\(state ?? "preview")\(index == 0 ? "" : "-\(index)").png"))
                    }
                    log.write("preview \(state ?? "?"): snapshots in \(directory.path)")
                }
            }
        }
    }

    /// `--preview-out <folder>`: where to save window PNGs.
    private static let outputDirectory: URL? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--preview-out"), arguments.indices.contains(index + 1) else { return nil }
        return URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
    }()

    /// Renders the window to PNG without screen recording. The glass (composited by WindowServer) won't
    /// show up this way, so we put the system window background underneath — the snapshot checks layout, not the material.
    @MainActor
    private static func snapshot(_ window: NSWindow, to url: URL) {
        let content = (window.contentView as? NSGlassEffectView)?.contentView
        guard let view = content ?? window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: view.bounds.size), xRadius: 18, yRadius: 18).fill()
        rep.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    @MainActor
    private static func showPanel(model: AppModel) {
        let hosting = NSHostingView(rootView: MenuView(model: model))
        let size = hosting.fittingSize
        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
        glass.cornerRadius = 18
        glass.contentView = hosting
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.contentView = glass
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - size.width - 80, y: screen.maxY - 8))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }
}
