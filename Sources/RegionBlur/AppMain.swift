import AppKit
import SwiftUI
import RegionBlurCore

@MainActor final class OverlayPanel: NSPanel {
    let regionID: UUID
    let visual = NSVisualEffectView()

    init(region: BlurRegion) {
        regionID = region.id
        super.init(contentRect: region.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        visual.frame = NSRect(origin: .zero, size: region.frame.size)
        visual.autoresizingMask = [.width, .height]
        visual.blendingMode = .behindWindow
        visual.state = .active
        contentView = visual
        apply(region)
    }

    func apply(_ region: BlurRegion, globallyVisible: Bool = true) {
        setFrame(region.frame, display: true)
        visual.material = switch region.effect.material {
        case .hudWindow: .hudWindow
        case .sidebar: .sidebar
        case .popover: .popover
        case .underWindowBackground: .underWindowBackground
        }
        alphaValue = region.effect.opacity
        ignoresMouseEvents = region.ignoresMouseEvents
        if region.isHidden || !globallyVisible { orderOut(nil) } else { orderFrontRegardless() }
    }
}

@MainActor final class SelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private var start: CGPoint?
    private var current: CGPoint?

    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        guard let start, let current else { onFinish?(nil); return }
        onFinish?(CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y)))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.18).setFill(); dirtyRect.fill()
        guard let start, let current else { return }
        let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
        NSColor.systemBlue.withAlphaComponent(0.8).setStroke(); NSBezierPath(rect: rect).stroke()
        NSColor.systemBlue.withAlphaComponent(0.12).setFill(); rect.fill()
    }
}

@MainActor final class AppController: NSObject, NSApplicationDelegate {
    private let store = SettingsStore.applicationStore()
    private var manager: RegionManager!
    private var panels: [UUID: OverlayPanel] = [:]
    private var statusItem: NSStatusItem!
    private var selectionWindows: [NSWindow] = []
    private var allVisible = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        manager = try? RegionManager(store: store) { [weak self] regions in self?.refresh(regions) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◫"
        buildMenu()
        manager.reloadPresentation()
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .option]) && event.keyCode == 11 { self?.beginSelection() }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .option]) && event.keyCode == 11 { self?.beginSelection(); return nil }
            return event
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "新建模糊区域  ⌥⌘B", action: #selector(beginSelection), keyEquivalent: "")
        menu.addItem(withTitle: "显示/隐藏全部", action: #selector(toggleAll), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    private func refresh(_ regions: [BlurRegion]) {
        let ids = Set(regions.map(\.id))
        for (id, panel) in panels where !ids.contains(id) { panel.close(); panels.removeValue(forKey: id) }
        for region in regions {
            let panel = panels[region.id] ?? { let p = OverlayPanel(region: region); panels[region.id] = p; return p }()
            panel.apply(region, globallyVisible: allVisible)
        }
    }

    @objc private func beginSelection() {
        guard selectionWindows.isEmpty else { return }
        for screen in NSScreen.screens {
            let window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.level = .screenSaver; window.isOpaque = false; window.backgroundColor = .clear; window.ignoresMouseEvents = false
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onFinish = { [weak self, weak window] localRect in
                guard let self, let window else { return }
                if let localRect, localRect.width >= 24, localRect.height >= 24 {
                    let origin = window.convertToScreen(NSRect(origin: localRect.origin, size: .zero)).origin
                    _ = self.manager.create(frame: CGRect(origin: origin, size: localRect.size))
                }
                self.finishSelection()
            }
            window.contentView = view; window.makeKeyAndOrderFront(nil); selectionWindows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finishSelection() { selectionWindows.forEach { $0.orderOut(nil) }; selectionWindows.removeAll() }

    @objc private func toggleAll() { allVisible.toggle(); manager.reloadPresentation(); refresh(manager.regions) }
    @objc private func quit() { NSApp.terminate(nil) }
}

@main
@MainActor struct RegionBlurApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppController()
        app.delegate = delegate
        app.run()
    }
}
