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
        visual.wantsLayer = true
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
        // NSVisualEffectView does not expose a blur-radius API. Combine its
        // live material with view alpha and a subtle tint so the slider has an
        // immediate, visible effect without capturing the screen.
        alphaValue = 1
        visual.alphaValue = CGFloat(0.35 + (region.effect.opacity * 0.65))
        visual.layer?.backgroundColor = NSColor.black.withAlphaComponent(CGFloat((1 - region.effect.opacity) * 0.32)).cgColor
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
    private var selectedRegionID: UUID?
    private var clarityWindow: NSWindow?
    private var claritySlider: NSSlider?

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
        let selectItem = NSMenuItem(title: "选择已有区域", action: nil, keyEquivalent: "")
        let selectMenu = NSMenu()
        for (index, region) in manager?.regions.enumerated() ?? [].enumerated() {
            let item = NSMenuItem(title: "区域 \(index + 1)", action: #selector(selectRegion(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = region.id.uuidString
            selectMenu.addItem(item)
        }
        selectItem.submenu = selectMenu
        menu.addItem(selectItem)
        menu.addItem(withTitle: "删除当前/最近区域", action: #selector(deleteSelected), keyEquivalent: "")
        menu.addItem(withTitle: "调节清晰度…", action: #selector(openClaritySlider), keyEquivalent: "")
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
        buildMenu()
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
                    let region = self.manager.create(frame: CGRect(origin: origin, size: localRect.size))
                    self.selectedRegionID = region.id
                }
                self.finishSelection()
            }
            window.contentView = view; window.makeKeyAndOrderFront(nil); selectionWindows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finishSelection() { selectionWindows.forEach { $0.orderOut(nil) }; selectionWindows.removeAll() }

    @objc private func toggleAll() { allVisible.toggle(); manager.reloadPresentation(); refresh(manager.regions) }
    @objc private func deleteSelected() {
        guard let id = selectedRegionID ?? manager.regions.last?.id else { return }
        manager.delete(id: id)
        self.selectedRegionID = nil
    }
    @objc private func selectRegion(_ item: NSMenuItem) {
        guard let idString = item.representedObject as? String, let id = UUID(uuidString: idString) else { return }
        selectedRegionID = id
    }
    @objc private func openClaritySlider() {
        guard let id = selectedRegionID ?? manager.regions.last?.id,
              let region = manager.regions.first(where: { $0.id == id }) else { return }
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 92), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        window.title = "区域清晰度"
        window.level = .floating
        window.isReleasedWhenClosed = false
        let slider = NSSlider(value: region.effect.opacity, minValue: 0.15, maxValue: 1.0, target: self, action: #selector(clarityChanged(_:)))
        slider.frame = NSRect(x: 24, y: 38, width: 252, height: 24)
        slider.tag = id.hashValue
        let label = NSTextField(labelWithString: "左边更清晰，右边更模糊")
        label.frame = NSRect(x: 24, y: 14, width: 252, height: 18)
        label.font = .systemFont(ofSize: 12)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(slider)
        window.contentView?.addSubview(label)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKey()
        clarityWindow = window; claritySlider = slider
    }
    @objc private func clarityChanged(_ slider: NSSlider) {
        guard let id = selectedRegionID ?? manager.regions.last?.id,
              var region = manager.regions.first(where: { $0.id == id }) else { return }
        region.effect.opacity = slider.doubleValue
        manager.update(region)
    }
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
