import AppKit
import SwiftUI
import RegionBlurCore
import ApplicationServices

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
    private struct WindowBinding {
        var pid: pid_t
        var offset: CGSize
        var element: AXUIElement?
    }
    private struct WindowState {
        var frame: CGRect
        var fullyCovered: Bool
    }
    private let store = SettingsStore.applicationStore()
    private var manager: RegionManager!
    private var panels: [UUID: OverlayPanel] = [:]
    private var statusItem: NSStatusItem!
    private var selectionWindows: [NSWindow] = []
    private var allVisible = true
    private var selectedRegionID: UUID?
    private var clarityWindow: NSWindow?
    private var claritySlider: NSSlider?
    private var globalOpacity = 0.82
    private var trackingTimer: Timer?
    private var bindings: [UUID: WindowBinding] = [:]
    private var pendingWindowApp: NSRunningApplication?
    private var pickingWindow = false
    private var automaticWindowPicking = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        manager = try? RegionManager(store: store) { [weak self] regions in self?.refresh(regions) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◫"
        buildMenu()
        manager.reloadPresentation()
        restoreSavedBindings()
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
        menu.addItem(withTitle: "跟随当前窗口", action: #selector(attachToFrontWindow), keyEquivalent: "")
        menu.addItem(withTitle: "点选窗口创建区域", action: #selector(createAttachedRegion), keyEquivalent: "")
        menu.addItem(withTitle: "授权辅助功能", action: #selector(requestAccessibility), keyEquivalent: "")
        let permissionItem = NSMenuItem(title: AXIsProcessTrusted() ? "辅助功能：已授权" : "辅助功能：未授权", action: nil, keyEquivalent: "")
        permissionItem.isEnabled = false
        menu.addItem(permissionItem)
        menu.addItem(withTitle: "点选窗口并自动遮罩", action: #selector(beginAutomaticWindowPick), keyEquivalent: "")
        menu.addItem(withTitle: "停止跟随", action: #selector(stopTracking), keyEquivalent: "")
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
                if self.automaticWindowPicking {
                    guard let localRect else { self.automaticWindowPicking = false; self.finishSelection(); return }
                    let point = window.convertToScreen(NSRect(origin: CGPoint(x: localRect.midX, y: localRect.midY), size: .zero)).origin
                    self.automaticWindowPicking = false
                    self.finishSelection()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.createAutomaticOverlay(at: point) }
                    return
                }
                if let localRect, localRect.width >= 24, localRect.height >= 24 {
                    let origin = window.convertToScreen(NSRect(origin: localRect.origin, size: .zero)).origin
                    let region = self.manager.create(frame: CGRect(origin: origin, size: localRect.size))
                    self.selectedRegionID = region.id
                    if let app = self.pendingWindowApp {
                        self.pendingWindowApp = nil
                        self.attach(regionID: region.id, to: app)
                    } else if self.pickingWindow {
                        let center = CGPoint(x: localRect.midX, y: localRect.midY)
                        let screenPoint = window.convertToScreen(NSRect(origin: center, size: .zero)).origin
                        if let app = self.applicationAtScreenPoint(screenPoint) {
                            self.attach(regionID: region.id, to: app)
                        }
                        self.pickingWindow = false
                    }
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
    @objc private func attachToFrontWindow() {
        guard let id = selectedRegionID ?? manager.regions.last?.id else { return }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        attach(regionID: id, to: app)
    }
    @objc private func createAttachedRegion() {
        pendingWindowApp = nil
        pickingWindow = true
        beginSelection()
    }
    @objc private func requestAccessibility() {
        guard !AXIsProcessTrusted() else {
            showAlert(title: "辅助功能已授权", message: "RegionBlur 当前可以读取窗口信息。")
            buildMenu()
            return
        }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        buildMenu()
    }
    @objc private func beginAutomaticWindowPick() {
        guard AXIsProcessTrusted() else { requestAccessibility(); return }
        automaticWindowPicking = true
        beginSelection()
    }
    private func createAutomaticOverlay(at screenPoint: CGPoint) {
        guard AXIsProcessTrusted() else { showAlert(title: "没有辅助功能权限", message: "请在系统设置中允许 RegionBlur 后重新尝试。"); buildMenu(); return }
        guard let windowElement = accessibilityWindow(at: screenPoint), let frame = windowFrame(windowElement) else {
            showAlert(title: "没有识别到窗口", message: "请点击普通应用窗口的内容区域，不要点击桌面、菜单栏或 RegionBlur 自己的面板。")
            return
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(windowElement, &pid) == .success, pid != ProcessInfo.processInfo.processIdentifier else { return }
        let region = manager.create(frame: frame)
        selectedRegionID = region.id
        attach(regionID: region.id, toPID: pid, element: windowElement)
    }
    private func showAlert(title: String, message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
    private func accessibilityWindow(at screenPoint: CGPoint) -> AXUIElement? {
        let screenHeight = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
        let axPoint = CGPoint(x: screenPoint.x, y: screenHeight - screenPoint.y)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(axPoint.x), Float(axPoint.y), &element) == .success,
              let element else { return nil }
        var windowValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowValue) == .success,
           let windowValue { return (windowValue as! AXUIElement) }
        return element
    }
    private func applicationAtScreenPoint(_ point: CGPoint) -> NSRunningApplication? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let screenHeight = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
        let cgPoint = CGPoint(x: point.x, y: screenHeight - point.y)
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let rawBounds = info[kCGWindowBounds as String] else { continue }
            let bounds = rawBounds as! CFDictionary
            guard let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(cgPoint) else { continue }
            return NSRunningApplication(processIdentifier: pid)
        }
        return nil
    }
    private func attach(regionID id: UUID, to app: NSRunningApplication) {
        guard let bounds = firstWindowFrame(pid: app.processIdentifier) else { return }
        attach(regionID: id, toPID: app.processIdentifier, element: nil, bounds: bounds, bundleIdentifier: app.bundleIdentifier ?? "")
    }
    private func attach(regionID id: UUID, toPID pid: pid_t, element: AXUIElement?, bounds suppliedBounds: CGRect? = nil, bundleIdentifier: String? = nil) {
        guard let bounds = suppliedBounds ?? element.flatMap(windowFrame) ?? firstWindowFrame(pid: pid) else { return }
        guard let region = manager.regions.first(where: { $0.id == id }) else { return }
        bindings[id] = WindowBinding(pid: pid, offset: CGSize(width: region.frame.minX - bounds.minX, height: region.frame.minY - bounds.minY), element: element)
        var attachedRegion = region
        attachedRegion.mode = .attached
        let bundle = bundleIdentifier ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        attachedRegion.attachment = WindowAttachment(bundleIdentifier: bundle, windowTitle: nil, relativeFrame: RectValue(region.frame), processID: pid)
        manager.update(attachedRegion)
        if trackingTimer == nil {
            trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.updateTrackedWindows() }
        }
        updateTrackedWindows()
    }
    @objc private func stopTracking() {
        guard let id = selectedRegionID ?? manager.regions.last?.id, var region = manager.regions.first(where: { $0.id == id }) else { return }
        bindings.removeValue(forKey: id)
        if bindings.isEmpty { trackingTimer?.invalidate(); trackingTimer = nil }
        region.mode = .fixed; region.attachment = nil; manager.update(region)
    }
    private func updateTrackedWindows() {
        for (id, binding) in bindings {
            guard var region = manager.regions.first(where: { $0.id == id }) else { continue }
            let appHidden = NSRunningApplication(processIdentifier: binding.pid)?.isHidden ?? false
            let exactFrame = binding.element.flatMap(windowFrame)
            guard !appHidden, let state = exactFrame.map({ WindowState(frame: $0, fullyCovered: false) }) ?? windowState(pid: binding.pid), !state.fullyCovered else {
                panels[id]?.orderOut(nil)
                continue
            }
            let bounds = state.frame
            region.mode = .attached
            region.frame.origin = CGPoint(x: bounds.minX + binding.offset.width, y: bounds.minY + binding.offset.height)
            manager.update(region)
            panels[id]?.apply(region, globallyVisible: allVisible)
        }
    }
    private func restoreSavedBindings() {
        for region in manager.regions where region.mode == .attached {
            guard let attachment = region.attachment else { continue }
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: attachment.bundleIdentifier).first
            if let app { attach(regionID: region.id, to: app) }
        }
    }
    private func windowFrame(_ window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?; var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef else { return nil }
        var point = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &point), AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        let screenHeight = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
        return CGRect(x: point.x, y: screenHeight - point.y - size.height, width: size.width, height: size.height)
    }
    private func firstWindowFrame(pid: pid_t) -> CGRect? {
        windowState(pid: pid)?.frame
    }
    private func windowState(pid: pid_t) -> WindowState? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let screenHeight = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
        var occluders: [CGRect] = []
        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  (info[kCGWindowIsOnscreen as String] as? Bool ?? true),
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"], w > 80, h > 50 else { continue }
            let frame = CGRect(x: x, y: screenHeight - y - h, width: w, height: h)
            if ownerPID == pid {
                return WindowState(frame: frame, fullyCovered: WindowOcclusion.isFullyCovered(target: frame, by: occluders))
            }
            if ownerPID != ProcessInfo.processInfo.processIdentifier { occluders.append(frame) }
        }
        return nil
    }
    @objc private func openClaritySlider() {
        guard !manager.regions.isEmpty else { return }
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 92), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        window.title = "区域清晰度"
        window.level = .floating
        window.isReleasedWhenClosed = false
        let slider = NSSlider(value: globalOpacity, minValue: 0.15, maxValue: 1.0, target: self, action: #selector(clarityChanged(_:)))
        slider.frame = NSRect(x: 24, y: 38, width: 252, height: 24)
        let label = NSTextField(labelWithString: "全局清晰度：左边更清晰，右边更模糊")
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
        globalOpacity = slider.doubleValue
        for var region in manager.regions {
            region.effect.opacity = globalOpacity
            manager.update(region)
        }
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
