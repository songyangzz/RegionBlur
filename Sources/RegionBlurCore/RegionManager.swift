import CoreGraphics
import Foundation

public final class RegionManager {
    public private(set) var regions: [BlurRegion]
    public private(set) var allVisible = true
    private let store: SettingsStoring
    private let onChange: ([BlurRegion]) -> Void

    public init(store: SettingsStoring, onChange: @escaping ([BlurRegion]) -> Void = { _ in }) throws {
        self.store = store
        regions = try store.load().regions.compactMap { $0.normalized(minimumSize: CGSize(width: 24, height: 24)) }
        self.onChange = onChange
    }

    @discardableResult
    public func create(frame: CGRect) -> BlurRegion {
        let candidate = BlurRegion(frame: frame)
        guard let region = candidate.normalized(minimumSize: CGSize(width: 24, height: 24)) else { return candidate }
        regions.append(region)
        changed()
        return region
    }

    public func update(_ region: BlurRegion) {
        guard let index = regions.firstIndex(where: { $0.id == region.id }),
              let normalized = region.normalized(minimumSize: CGSize(width: 24, height: 24)) else { return }
        regions[index] = normalized
        changed()
    }

    public func delete(id: UUID) {
        regions.removeAll { $0.id == id }
        changed()
    }

    public func setAllVisible(_ visible: Bool) {
        allVisible = visible
        onChange(regions)
    }

    public func reloadPresentation() { onChange(regions) }

    private func changed() {
        try? store.save(AppSettings(regions: regions))
        onChange(regions)
    }
}
