# macOS Region Blur Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and package a native menu-bar app that creates persistent rectangular blur overlays fixed to a screen or attached to an application window.

**Architecture:** A Swift Package executable hosts an AppKit menu-bar application. `RegionManager` owns serializable region models and maps each visible region to one `BlurOverlayPanel`; selection, editing, hotkeys, persistence, screen reconciliation, and Accessibility-based window tracking are isolated behind focused types.

**Tech Stack:** Swift 6, AppKit, SwiftUI, ApplicationServices Accessibility API, Carbon hotkeys, XCTest, Swift Package Manager, shell-based `.app` packaging.

**Spec:** `docs/superpowers/specs/2026-09-20-macos-region-blur-design.md`

## Global Constraints

- Target Apple Silicon and macOS 26; set the package deployment floor to macOS 14 so the produced binary can run on supported recent systems.
- Use only Apple frameworks and Swift Package Manager; do not add network-fetched runtime dependencies.
- Fixed overlays must not request Screen Recording permission.
- Request Accessibility permission only when the user invokes window-following behavior.
- Do not capture, upload, persist, or inspect screen pixels or user-entered content.
- Keep the application accessory-only: menu-bar item present, no persistent Dock icon.
- First release supports rectangular regions only.

## Review Focus

- A saved region with non-finite, negative, or off-screen geometry must be normalized into a usable visible rectangle instead of creating an unreachable panel; Task 1 and Task 7 test this.
- Corrupt or partially written JSON must be backed up and replaced by an empty in-memory configuration without terminating the app; Task 1 tests this.
- A selection dragged in any direction, including across negative global coordinates on a secondary display, must produce the same standardized rectangle; Task 3 tests this.
- Losing Accessibility permission or the target window must hide only the affected attached overlays while fixed overlays remain visible; Task 6 tests this.
- Re-registering a conflicting global shortcut must leave the menu command usable and report the registration error without crashing; Task 5 tests this.

---

## File Structure

Create these focused files:

- `Package.swift` — package, executable, test targets, and macOS deployment floor.
- `Sources/RegionBlur/AppMain.swift` — process entry point and application delegate.
- `Sources/RegionBlur/AppController.swift` — component composition and top-level commands.
- `Sources/RegionBlur/Models/BlurRegion.swift` — codable region, geometry, effect, and attachment models.
- `Sources/RegionBlur/Persistence/SettingsStore.swift` — atomic JSON load/save and corrupt-file recovery.
- `Sources/RegionBlur/Overlay/BlurOverlayPanel.swift` — one visual blur panel and edit chrome.
- `Sources/RegionBlur/Overlay/RegionManager.swift` — region collection and panel synchronization.
- `Sources/RegionBlur/Selection/SelectionController.swift` — multi-screen drag selection.
- `Sources/RegionBlur/Selection/SelectionOverlayWindow.swift` — selection UI for one display.
- `Sources/RegionBlur/Editing/EditController.swift` — edit-mode orchestration and region context actions.
- `Sources/RegionBlur/Menu/MenuBarController.swift` — status item and menu actions.
- `Sources/RegionBlur/HotKey/HotKeyManager.swift` — Carbon global shortcut registration.
- `Sources/RegionBlur/Tracking/AccessibilityClient.swift` — small testable wrapper around AX APIs.
- `Sources/RegionBlur/Tracking/WindowTracker.swift` — target selection, observation, loss, and recovery.
- `Sources/RegionBlur/Screens/ScreenReconciler.swift` — visible-frame and display-layout correction.
- `Sources/RegionBlur/Settings/SettingsView.swift` — keyboard shortcut and privacy/permission copy.
- `Resources/Info.plist` — accessory-app and bundle metadata.
- `scripts/build-app.sh` — release build and deterministic `.app` bundle assembly.
- `Tests/RegionBlurTests/*.swift` — unit tests grouped by owning component.

### Task 1: Package, Region Model, and Durable Settings

**Files:**
- Create: `Package.swift`
- Create: `Sources/RegionBlur/Models/BlurRegion.swift`
- Create: `Sources/RegionBlur/Persistence/SettingsStore.swift`
- Create: `Tests/RegionBlurTests/BlurRegionTests.swift`
- Create: `Tests/RegionBlurTests/SettingsStoreTests.swift`

**Interfaces:**
- Produces: `BlurRegion`, `RegionMode`, `BlurEffect`, `WindowAttachment`, `AppSettings`.
- Produces: `SettingsStoring.load() throws -> AppSettings` and `save(_:) throws`.
- Consumes: Foundation only.

- [ ] **Step 1: Create the Swift package and failing model tests**

Define an executable target named `RegionBlur`, a test target named `RegionBlurTests`, and macOS `.v14`. Add tests proving Codable round trips preserve IDs and attachment data, and that `BlurRegion.normalized(minimumSize:)` rejects non-finite values and standardizes negative width/height:

```swift
func testNormalizedStandardizesAndClampsMinimumSize() throws {
    let region = BlurRegion(frame: CGRect(x: 100, y: 80, width: -40, height: -10))
    let result = try XCTUnwrap(region.normalized(minimumSize: CGSize(width: 24, height: 24)))
    XCTAssertEqual(result.frame, CGRect(x: 60, y: 70, width: 40, height: 24))
}

func testNormalizedRejectsNonFiniteGeometry() {
    let region = BlurRegion(frame: CGRect(x: .nan, y: 0, width: 100, height: 100))
    XCTAssertNil(region.normalized(minimumSize: CGSize(width: 24, height: 24)))
}
```

- [ ] **Step 2: Run the model tests and verify they fail**

Run: `swift test --filter BlurRegionTests`

Expected: compilation fails because `BlurRegion` is undefined.

- [ ] **Step 3: Implement the model types**

Use a Codable `RectValue` rather than relying on platform Codable behavior:

```swift
struct RectValue: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

enum RegionMode: String, Codable, Sendable { case fixed, attached }
enum BlurMaterial: String, Codable, CaseIterable, Sendable { case hudWindow, sidebar, popover, underWindowBackground }

struct BlurEffect: Codable, Equatable, Sendable {
    var material: BlurMaterial = .hudWindow
    var opacity: Double = 0.82
}

struct WindowAttachment: Codable, Equatable, Sendable {
    var bundleIdentifier: String
    var savedWindowTitle: String?
    var relativeFrame: RectValue
}

struct BlurRegion: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var frame: CGRect
    var mode: RegionMode = .fixed
    var effect = BlurEffect()
    var ignoresMouseEvents = true
    var isHidden = false
    var displayID: UInt32?
    var attachment: WindowAttachment?
    func normalized(minimumSize: CGSize) -> BlurRegion?
}
```

- [ ] **Step 4: Add failing persistence tests**

Inject the settings URL into `SettingsStore`. Test an empty first launch, a save/load round trip, and corrupt recovery:

```swift
func testCorruptFileIsBackedUpAndReturnsEmptySettings() throws {
    try Data("{broken".utf8).write(to: settingsURL)
    let loaded = try store.load()
    XCTAssertEqual(loaded.regions, [])
    XCTAssertTrue(fileManager.fileExists(atPath: settingsURL.appendingPathExtension("corrupt").path))
}
```

- [ ] **Step 5: Run persistence tests and verify they fail**

Run: `swift test --filter SettingsStoreTests`

Expected: compilation fails because `SettingsStore` is undefined.

- [ ] **Step 6: Implement atomic settings persistence**

Define:

```swift
struct AppSettings: Codable, Equatable, Sendable {
    var regions: [BlurRegion] = []
    var shortcutKeyCode: UInt32 = 11
    var shortcutModifiers: UInt32 = 0
}

protocol SettingsStoring {
    func load() throws -> AppSettings
    func save(_ settings: AppSettings) throws
}
```

`save(_:)` writes encoded JSON with `.atomic`. `load()` returns an empty configuration when absent; when decoding fails, it removes an existing `.corrupt` backup, moves the bad file there, and returns an empty configuration.

- [ ] **Step 7: Run Task 1 tests**

Run: `swift test --filter 'BlurRegionTests|SettingsStoreTests'`

Expected: all Task 1 tests pass.

- [ ] **Step 8: Commit Task 1**

```bash
git add Package.swift Sources/RegionBlur/Models Sources/RegionBlur/Persistence Tests/RegionBlurTests
git commit -m "feat: add region model and settings persistence"
```

### Task 2: Blur Panels and Region Lifecycle

**Files:**
- Create: `Sources/RegionBlur/Overlay/BlurOverlayPanel.swift`
- Create: `Sources/RegionBlur/Overlay/RegionManager.swift`
- Create: `Tests/RegionBlurTests/RegionManagerTests.swift`

**Interfaces:**
- Consumes: `BlurRegion`, `SettingsStoring` from Task 1.
- Produces: `OverlayPresenting.apply(region:)`, `setEditing(_:)`, `close()`.
- Produces: `RegionManaging.create(frame:)`, `update(_:)`, `delete(id:)`, `setAllVisible(_:)`, and `setEditing(_:)`.

- [ ] **Step 1: Write failing lifecycle tests with a panel spy**

Test creation, update, deletion, global hide, and persistence. The factory returns `OverlaySpy` objects so tests do not display windows:

```swift
func testCreateBuildsPanelAndPersistsRegion() throws {
    let created = manager.create(frame: CGRect(x: 10, y: 20, width: 200, height: 100))
    XCTAssertEqual(factory.panels[created.id]?.appliedRegion, created)
    XCTAssertEqual(store.saved.regions, [created])
}

func testGlobalHideOrdersEveryPanelOutWithoutChangingPerRegionHiddenFlag() {
    let region = manager.create(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    manager.setAllVisible(false)
    XCTAssertFalse(factory.panels[region.id]!.isPresented)
    XCTAssertFalse(manager.regions[0].isHidden)
}
```

- [ ] **Step 2: Run and verify lifecycle tests fail**

Run: `swift test --filter RegionManagerTests`

Expected: compilation fails because `RegionManager` and overlay protocols do not exist.

- [ ] **Step 3: Implement `BlurOverlayPanel`**

Create a borderless `NSPanel` with `.nonactivatingPanel`, clear background, `hasShadow = false`, level `.floating`, and collection behavior `[.canJoinAllSpaces, .fullScreenAuxiliary]`. Fill its content view with an `NSVisualEffectView`, map `BlurMaterial` to `NSVisualEffectView.Material`, set `.behindWindow`, and apply the saved opacity. `apply(region:)` updates frame, visibility, material, opacity, and `ignoresMouseEvents`.

- [ ] **Step 4: Implement `RegionManager`**

Normalize new frames to a 24×24 minimum, create one panel per visible valid region, and save after every mutation. Keep `allVisible` separate from each region's persisted `isHidden` flag. On load, skip invalid models and synchronize panels from the surviving list.

- [ ] **Step 5: Run Task 2 tests**

Run: `swift test --filter RegionManagerTests`

Expected: all lifecycle tests pass.

- [ ] **Step 6: Commit Task 2**

```bash
git add Sources/RegionBlur/Overlay Tests/RegionBlurTests/RegionManagerTests.swift
git commit -m "feat: manage native blur overlay panels"
```

### Task 3: Multi-Screen Drag Selection

**Files:**
- Create: `Sources/RegionBlur/Selection/SelectionController.swift`
- Create: `Sources/RegionBlur/Selection/SelectionOverlayWindow.swift`
- Create: `Tests/RegionBlurTests/SelectionGeometryTests.swift`

**Interfaces:**
- Consumes: `RegionManaging.create(frame:)` from Task 2.
- Produces: `SelectionController.begin()`, `cancel()`, and `finishDrag(start:end:)`.
- Produces: pure `SelectionGeometry.rectangle(from:to:) -> CGRect`.

- [ ] **Step 1: Write failing geometry tests**

Cover all drag directions and negative global coordinates:

```swift
func testRectangleIsIndependentOfDragDirection() {
    XCTAssertEqual(
        SelectionGeometry.rectangle(from: CGPoint(x: 80, y: 50), to: CGPoint(x: -20, y: -10)),
        CGRect(x: -20, y: -10, width: 100, height: 60)
    )
}
```

- [ ] **Step 2: Run and verify selection tests fail**

Run: `swift test --filter SelectionGeometryTests`

Expected: compilation fails because `SelectionGeometry` is undefined.

- [ ] **Step 3: Implement selection geometry and overlay windows**

Create one borderless window per `NSScreen`, positioned at that screen's global frame. The overlay dims with a translucent black view, tracks mouse-down/drag/up, and draws a clear bordered selection rectangle. Convert local event coordinates using `window.convertPoint(toScreen:)` before sending them to the controller.

- [ ] **Step 4: Implement selection lifecycle**

`begin()` cancels an existing session, creates all screen overlays, activates the app, and installs Escape handling. `finishDrag` standardizes the rectangle, ignores selections below 24×24 points, calls `RegionManaging.create(frame:)`, and tears down every selector window.

- [ ] **Step 5: Run Task 3 tests**

Run: `swift test --filter SelectionGeometryTests`

Expected: all selection geometry tests pass.

- [ ] **Step 6: Commit Task 3**

```bash
git add Sources/RegionBlur/Selection Tests/RegionBlurTests/SelectionGeometryTests.swift
git commit -m "feat: add multi-screen region selection"
```

### Task 4: Region Editing and Context Actions

**Files:**
- Create: `Sources/RegionBlur/Editing/EditController.swift`
- Modify: `Sources/RegionBlur/Overlay/BlurOverlayPanel.swift`
- Modify: `Sources/RegionBlur/Overlay/RegionManager.swift`
- Create: `Tests/RegionBlurTests/EditGeometryTests.swift`

**Interfaces:**
- Consumes: `RegionManaging.update(_:)`, `delete(id:)`, `setEditing(_:)`.
- Produces: `EditGeometry.resized(frame:handle:translation:minimumSize:) -> CGRect`.
- Produces: `EditController.enter()`, `exit()`, `move(id:translation:)`, and `resize(id:handle:translation:)`.

- [ ] **Step 1: Write failing edit geometry tests**

Test moving and each corner handle. Include a resize that tries to cross the opposite edge and verify the result remains at least 24×24:

```swift
func testNorthWestResizeStopsAtMinimumSize() {
    let result = EditGeometry.resized(
        frame: CGRect(x: 10, y: 10, width: 100, height: 80),
        handle: .northWest,
        translation: CGSize(width: 200, height: -200),
        minimumSize: CGSize(width: 24, height: 24)
    )
    XCTAssertEqual(result.size, CGSize(width: 24, height: 24))
}
```

- [ ] **Step 2: Run and verify edit tests fail**

Run: `swift test --filter EditGeometryTests`

Expected: compilation fails because `EditGeometry` is undefined.

- [ ] **Step 3: Add edit chrome to each panel**

When editing, set `ignoresMouseEvents = false`, show a one-point accent border and four 10-point corner handles, and attach pan gestures for movement and resizing. When editing ends, remove edit chrome and restore each model's `ignoresMouseEvents` value.

- [ ] **Step 4: Add region context actions**

Build an `NSMenu` with Hide/Show, Mouse Passthrough, material choices, opacity values 40/60/80/100%, Attach to Window, Fix to Screen, and Delete. Route mutations through `RegionManager`; never mutate a panel-only copy.

- [ ] **Step 5: Implement `EditController` and run tests**

Run: `swift test --filter EditGeometryTests`

Expected: all edit geometry tests pass.

- [ ] **Step 6: Commit Task 4**

```bash
git add Sources/RegionBlur/Editing Sources/RegionBlur/Overlay Tests/RegionBlurTests/EditGeometryTests.swift
git commit -m "feat: add overlay editing and context actions"
```

### Task 5: Menu Bar, Global Hotkey, and Settings

**Files:**
- Create: `Sources/RegionBlur/HotKey/HotKeyManager.swift`
- Create: `Sources/RegionBlur/Menu/MenuBarController.swift`
- Create: `Sources/RegionBlur/Settings/SettingsView.swift`
- Create: `Tests/RegionBlurTests/HotKeyManagerTests.swift`

**Interfaces:**
- Consumes: selection, editing, and global visibility commands from Tasks 2–4.
- Produces: `HotKeyRegistering.register(_ shortcut:onPressed:) -> Result<Void, HotKeyError>` and `unregister()`.
- Produces: `MenuBarController` callbacks for create, edit, visibility, settings, and quit.

- [ ] **Step 1: Write failing hotkey state tests**

Wrap Carbon calls behind `CarbonHotKeyClient`. Test successful registration, explicit conflict failure, unregister-before-reregister, and callback dispatch:

```swift
func testConflictIsReportedAndExistingHandlerIsNotLost() {
    client.registerResult = eventHotKeyExistsErr
    let result = manager.register(.defaultBlurShortcut, onPressed: {})
    XCTAssertEqual(result, .failure(.alreadyInUse))
    XCTAssertFalse(manager.isRegistered)
}
```

- [ ] **Step 2: Run and verify hotkey tests fail**

Run: `swift test --filter HotKeyManagerTests`

Expected: compilation fails because `HotKeyManager` is undefined.

- [ ] **Step 3: Implement Carbon hotkey registration**

Register `⌥⌘B` using Carbon `RegisterEventHotKey`, install one application event handler, retain the returned reference, and unregister before replacement or deinit. Map `eventHotKeyExistsErr` to `.alreadyInUse`; return other OSStatus values as `.systemStatus(Int32)`.

- [ ] **Step 4: Implement the status menu and settings window**

Add Create Region, Edit Regions, Hide/Show All, Settings, and Quit. Keep Create Region available even when hotkey registration fails. The SwiftUI settings view shows the current shortcut, registration error, startup restore behavior, and the explicit statement that overlays may not appear in captures or screen sharing.

- [ ] **Step 5: Run Task 5 tests**

Run: `swift test --filter HotKeyManagerTests`

Expected: all hotkey tests pass.

- [ ] **Step 6: Commit Task 5**

```bash
git add Sources/RegionBlur/HotKey Sources/RegionBlur/Menu Sources/RegionBlur/Settings Tests/RegionBlurTests/HotKeyManagerTests.swift
git commit -m "feat: add menu bar controls and global shortcut"
```

### Task 6: Accessibility Window Attachment and Tracking

**Files:**
- Create: `Sources/RegionBlur/Tracking/AccessibilityClient.swift`
- Create: `Sources/RegionBlur/Tracking/WindowTracker.swift`
- Modify: `Sources/RegionBlur/Editing/EditController.swift`
- Modify: `Sources/RegionBlur/Overlay/RegionManager.swift`
- Create: `Tests/RegionBlurTests/WindowTrackerTests.swift`

**Interfaces:**
- Consumes: region update and per-region presentation methods from `RegionManager`.
- Produces: `AccessibilityProviding.isTrusted(prompt:) -> Bool`, `window(at:) -> TrackedWindow?`, and observer events.
- Produces: `WindowTracker.attach(regionID:to:)`, `start()`, `stop()`, and `handle(_:)`.

- [ ] **Step 1: Write failing tracking tests using a fake AX client**

Test relative-frame conversion, move/resize updates, target loss, permission revocation, and unique restoration. Confirm fixed regions are untouched:

```swift
func testPermissionLossHidesAttachedRegionOnly() {
    tracker.handle(.trustChanged(false))
    XCTAssertEqual(presenter.hiddenRegionIDs, [attached.id])
    XCTAssertFalse(presenter.hiddenRegionIDs.contains(fixed.id))
}

func testAmbiguousRecoveryKeepsOverlayHidden() {
    client.matchingWindows = [candidateA, candidateB]
    tracker.handle(.applicationLaunched(bundleIdentifier: "com.example.Editor"))
    XCTAssertTrue(presenter.hiddenRegionIDs.contains(attached.id))
}
```

- [ ] **Step 2: Run and verify tracking tests fail**

Run: `swift test --filter WindowTrackerTests`

Expected: compilation fails because the tracking types are undefined.

- [ ] **Step 3: Implement the Accessibility wrapper**

Use `AXIsProcessTrustedWithOptions` only with `prompt: true` after an explicit Attach to Window command. Resolve the clicked window through frontmost application AX elements and window bounds. Register `AXObserver` notifications for moved, resized, destroyed, and focused-window changes. Convert AX top-left coordinates to AppKit global bottom-left coordinates using the union of active screen frames.

- [ ] **Step 4: Implement tracker state transitions**

On attachment, save Bundle Identifier, optional title used only for matching, and `relativeFrame`. On move/resize, derive the overlay global frame and update the region without changing its relative frame. On loss or trust revocation, hide only attached overlays. On application/window return, restore only when exactly one candidate matches; ambiguous results remain hidden.

- [ ] **Step 5: Connect Attach and Fix context actions**

Attach enters a crosshair selection state, identifies the clicked accessible window, computes the region's relative frame, updates the model to `.attached`, and starts observation. Fix converts the current frame to `.fixed`, clears `attachment`, records the current display ID, and removes observation.

- [ ] **Step 6: Run Task 6 tests**

Run: `swift test --filter WindowTrackerTests`

Expected: all tracking tests pass.

- [ ] **Step 7: Commit Task 6**

```bash
git add Sources/RegionBlur/Tracking Sources/RegionBlur/Editing Sources/RegionBlur/Overlay Tests/RegionBlurTests/WindowTrackerTests.swift
git commit -m "feat: attach blur regions to application windows"
```

### Task 7: Screen Layout Reconciliation

**Files:**
- Create: `Sources/RegionBlur/Screens/ScreenReconciler.swift`
- Modify: `Sources/RegionBlur/Overlay/RegionManager.swift`
- Create: `Tests/RegionBlurTests/ScreenReconcilerTests.swift`

**Interfaces:**
- Consumes: fixed `BlurRegion` models.
- Produces: `ScreenReconciler.reconcile(regions:screens:mainScreenID:) -> [BlurRegion]`.
- Produces: `ScreenDescriptor(id: UInt32, frame: CGRect, visibleFrame: CGRect)`.

- [ ] **Step 1: Write failing reconciliation tests**

Cover a disconnected display, a resolution reduction, an already visible frame, a region larger than the visible frame, and invalid saved geometry:

```swift
func testDisconnectedDisplayMovesRegionIntoMainVisibleFrame() {
    let result = reconciler.reconcile(
        regions: [regionOnMissingDisplay],
        screens: [mainScreen],
        mainScreenID: mainScreen.id
    )
    XCTAssertTrue(mainScreen.visibleFrame.contains(result[0].frame))
    XCTAssertEqual(result[0].displayID, mainScreen.id)
}
```

- [ ] **Step 2: Run and verify screen tests fail**

Run: `swift test --filter ScreenReconcilerTests`

Expected: compilation fails because `ScreenReconciler` is undefined.

- [ ] **Step 3: Implement screen reconciliation**

For fixed regions, choose the recorded display when present; otherwise use the main display. Normalize geometry, shrink only when the region is larger than the visible frame, then clamp its origin so the full region is reachable. Do not modify attached region geometry in this component.

- [ ] **Step 4: Subscribe to display changes**

Observe `NSApplication.didChangeScreenParametersNotification`, rebuild screen descriptors from `NSScreen.screens`, reconcile fixed regions, refresh panels, and persist only if geometry changed.

- [ ] **Step 5: Run Task 7 tests**

Run: `swift test --filter ScreenReconcilerTests`

Expected: all reconciliation tests pass.

- [ ] **Step 6: Commit Task 7**

```bash
git add Sources/RegionBlur/Screens Sources/RegionBlur/Overlay Tests/RegionBlurTests/ScreenReconcilerTests.swift
git commit -m "feat: keep overlays reachable across display changes"
```

### Task 8: Application Composition, Packaging, and End-to-End Verification

**Files:**
- Create: `Sources/RegionBlur/AppMain.swift`
- Create: `Sources/RegionBlur/AppController.swift`
- Create: `Resources/Info.plist`
- Create: `scripts/build-app.sh`
- Create: `README.md`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: all components from Tasks 1–7.
- Produces: executable entry point and `outputs/RegionBlur.app`.

- [ ] **Step 1: Add the application entry point and composition root**

Create `@main enum RegionBlurMain` that initializes `NSApplication`, sets `.accessory` activation policy, installs `AppDelegate`, and runs. `AppController.start()` loads settings, reconciles fixed regions, creates panels, starts the tracker for saved attachments when trusted, registers the shortcut, and constructs the status menu. `applicationWillTerminate` saves current state and unregisters observers/hotkeys.

- [ ] **Step 2: Add bundle metadata and packaging script**

Set bundle identifier `local.codex.RegionBlur`, `LSUIElement` to true, minimum system version 14.0, and copyright text. `scripts/build-app.sh` must:

```bash
#!/bin/zsh
set -euo pipefail
swift build -c release --arch arm64
app_dir="outputs/RegionBlur.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp .build/arm64-apple-macosx/release/RegionBlur "$app_dir/Contents/MacOS/RegionBlur"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
```

- [ ] **Step 3: Add usage and permission documentation**

Document build requirements, `./scripts/build-app.sh`, opening `outputs/RegionBlur.app`, `⌥⌘B`, editing, attachment permission, uninstalling by deleting the app, and the explicit limitation that screen sharing or capture may omit the overlay.

- [ ] **Step 4: Run the complete automated suite**

Run: `swift test`

Expected: all tests pass with zero failures.

- [ ] **Step 5: Build and verify the application bundle**

Run: `chmod +x scripts/build-app.sh && ./scripts/build-app.sh`

Expected: `outputs/RegionBlur.app` exists and `codesign --verify --deep --strict outputs/RegionBlur.app` exits successfully.

- [ ] **Step 6: Launch and complete manual smoke checks**

Run: `open outputs/RegionBlur.app`.

Verify: menu icon appears; `⌥⌘B` creates a blur rectangle; underlying controls remain clickable; edit mode moves/resizes/deletes; Hide All works; quitting and reopening restores fixed regions; Attach requests Accessibility permission only at that moment; an attached overlay follows a TextEdit window; closing TextEdit hides that overlay; disconnect/reconnect or simulated screen-layout changes keep fixed overlays reachable.

- [ ] **Step 7: Inspect logs and repository state**

Run: `log show --last 5m --predicate 'process == "RegionBlur"' --style compact` and `git status --short`.

Expected: no crash, assertion, repeated permission prompt, or unexpected tracked files. The only ignored build output is `.build/`; the user-facing `.app` remains in `outputs/`.

- [ ] **Step 8: Commit Task 8**

```bash
git add Sources/RegionBlur/AppMain.swift Sources/RegionBlur/AppController.swift Resources/Info.plist scripts/build-app.sh README.md .gitignore outputs/RegionBlur.app
git commit -m "feat: package RegionBlur menu bar application"
```

## Final Verification

- [ ] Run `swift test` and record the number of passing tests.
- [ ] Run `./scripts/build-app.sh` from a clean working tree.
- [ ] Run `codesign --verify --deep --strict outputs/RegionBlur.app`.
- [ ] Repeat the manual smoke checks from Task 8 on macOS 26.5.1 Apple Silicon.
- [ ] Review `git diff HEAD^` and `git status --short` for generated or unrelated files.
- [ ] Confirm the delivered app requests Accessibility permission only when Attach to Window is selected and never requests Screen Recording permission.

