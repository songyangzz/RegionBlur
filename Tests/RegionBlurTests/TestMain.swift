import Foundation
import CoreGraphics
import RegionBlurCore

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

func testRegionNormalization() throws {
    let region = BlurRegion(frame: CGRect(x: 100, y: 80, width: -40, height: -10))
    guard let result = region.normalized(minimumSize: CGSize(width: 24, height: 24)) else {
        throw TestFailure(description: "valid geometry was rejected")
    }
    try expect(result.frame == CGRect(x: 100, y: 80, width: 40, height: 24), "geometry was not clamped: \(result.frame)")
    try expect(BlurRegion(frame: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)).normalized(minimumSize: CGSize(width: 24, height: 24)) == nil, "non-finite geometry accepted")
}

func testRegionCodableRoundTrip() throws {
    var region = BlurRegion(frame: CGRect(x: 1, y: 2, width: 3, height: 4))
    region.mode = .attached
    region.attachment = WindowAttachment(bundleIdentifier: "com.example.App", windowTitle: "Document", relativeFrame: RectValue(region.frame))
    let decoded = try JSONDecoder().decode(BlurRegion.self, from: JSONEncoder().encode(region))
    try expect(decoded == region, "round trip changed region")
}

func testSettingsStore() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("settings.json")
    let store = SettingsStore(url: url)
    let empty = try store.load()
    try expect(empty == AppSettings(), "missing file was not empty")
    let expected = AppSettings(regions: [BlurRegion(frame: CGRect(x: 1, y: 2, width: 80, height: 60))])
    try store.save(expected)
    let loaded = try store.load()
    try expect(loaded == expected, "settings round trip failed")
    try Data("{broken".utf8).write(to: url)
    let recovered = try store.load()
    try expect(recovered.regions.isEmpty, "corrupt file did not recover")
    try expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path), "corrupt backup missing")
}

final class MemorySettingsStore: SettingsStoring {
    var settings = AppSettings()
    func load() throws -> AppSettings { settings }
    func save(_ settings: AppSettings) throws { self.settings = settings }
}

func testRegionManagerLifecycle() throws {
    let store = MemorySettingsStore()
    var changes = 0
    let manager = try RegionManager(store: store) { _ in changes += 1 }
    let region = manager.create(frame: CGRect(x: 10, y: 20, width: 100, height: 80))
    try expect(manager.regions == [region], "region was not created")
    try expect(store.settings.regions == [region], "region was not persisted")
    try expect(changes == 1, "create did not notify presenter")
    manager.setAllVisible(false)
    try expect(manager.allVisible == false, "global visibility not updated")
    try expect(manager.regions[0].isHidden == false, "global hide changed persisted per-region state")
    manager.delete(id: region.id)
    try expect(manager.regions.isEmpty, "region was not deleted")
}

func testRegionManagerUpdatesEffectAndDeletesSelectedRegion() throws {
    let manager = try RegionManager(store: MemorySettingsStore())
    var region = manager.create(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    region.effect.opacity = 0.35
    manager.update(region)
    try expect(manager.regions.first?.effect.opacity == 0.35, "clarity update was not stored")
    manager.delete(id: region.id)
    try expect(manager.regions.isEmpty, "selected region was not deleted")
}

func testWindowOcclusionRequiresCompleteCoverage() throws {
    let target = CGRect(x: 0, y: 0, width: 100, height: 100)
    try expect(WindowOcclusion.isFullyCovered(target: target, by: [CGRect(x: 0, y: 0, width: 100, height: 100)]), "full cover was not detected")
    try expect(WindowOcclusion.isFullyCovered(target: target, by: [CGRect(x: 0, y: 0, width: 50, height: 100), CGRect(x: 50, y: 0, width: 50, height: 100)]), "combined cover was not detected")
    try expect(!WindowOcclusion.isFullyCovered(target: target, by: [CGRect(x: 0, y: 0, width: 90, height: 100)]), "partial cover was treated as hidden")
}

func testWindowTrackingMenuIsUnified() throws {
    try expect(MenuConfiguration.windowTrackingTitles == ["点选窗口并自动遮罩"], "window tracking menu still exposes legacy actions")
}

func testAutomaticTrackingResizesOverlayWithWindow() throws {
    let windowFrame = CGRect(x: 120, y: 80, width: 900, height: 700)
    let oldOverlay = CGRect(x: 120, y: 80, width: 700, height: 500)
    try expect(WindowTrackingGeometry.trackedFrame(windowFrame: windowFrame, overlayFrame: oldOverlay, resizesToWindow: true) == windowFrame, "automatic overlay did not follow window size")
    try expect(WindowTrackingGeometry.trackedFrame(windowFrame: windowFrame, overlayFrame: oldOverlay, resizesToWindow: false) == CGRect(x: 120, y: 80, width: 700, height: 500), "fixed-size overlay was resized unexpectedly")
}

@main
enum TestMain {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("region normalization", testRegionNormalization),
            ("region codable", testRegionCodableRoundTrip),
            ("settings store", testSettingsStore)
            ,("region manager", testRegionManagerLifecycle)
            ,("region edit and delete", testRegionManagerUpdatesEffectAndDeletesSelectedRegion)
            ,("window occlusion", testWindowOcclusionRequiresCompleteCoverage)
            ,("unified window tracking menu", testWindowTrackingMenuIsUnified)
            ,("automatic tracking resizes overlay", testAutomaticTrackingResizesOverlayWithWindow)
        ]
        for (name, test) in tests {
            try test()
            print("PASS \(name)")
        }
        print("PASS \(tests.count) tests")
    }
}
