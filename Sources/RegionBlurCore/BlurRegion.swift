import Foundation
import CoreGraphics

public struct RectValue: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public enum RegionMode: String, Codable, Sendable { case fixed, attached }

public enum BlurMaterial: String, Codable, CaseIterable, Sendable {
    case hudWindow, sidebar, popover, underWindowBackground
}

public struct BlurEffect: Codable, Equatable, Sendable {
    public var material: BlurMaterial
    public var opacity: Double

    public init(material: BlurMaterial = .hudWindow, opacity: Double = 0.82) {
        self.material = material
        self.opacity = opacity
    }
}

public struct WindowAttachment: Codable, Equatable, Sendable {
    public var bundleIdentifier: String
    public var windowTitle: String?
    public var relativeFrame: RectValue

    public init(bundleIdentifier: String, windowTitle: String?, relativeFrame: RectValue) {
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.relativeFrame = relativeFrame
    }
}

public struct BlurRegion: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    private var storedFrame: RectValue
    public var mode: RegionMode
    public var effect: BlurEffect
    public var ignoresMouseEvents: Bool
    public var isHidden: Bool
    public var displayID: UInt32?
    public var attachment: WindowAttachment?

    public var frame: CGRect {
        get { storedFrame.cgRect }
        set { storedFrame = RectValue(newValue) }
    }

    public init(
        id: UUID = UUID(),
        frame: CGRect,
        mode: RegionMode = .fixed,
        effect: BlurEffect = BlurEffect(),
        ignoresMouseEvents: Bool = true,
        isHidden: Bool = false,
        displayID: UInt32? = nil,
        attachment: WindowAttachment? = nil
    ) {
        self.id = id
        storedFrame = RectValue(frame)
        self.mode = mode
        self.effect = effect
        self.ignoresMouseEvents = ignoresMouseEvents
        self.isHidden = isHidden
        self.displayID = displayID
        self.attachment = attachment
    }

    public func normalized(minimumSize: CGSize) -> BlurRegion? {
        let values = [frame.minX, frame.minY, frame.width, frame.height]
        guard values.allSatisfy(\.isFinite) else { return nil }
        var copy = self
        var rect = frame.standardized
        rect.size.width = max(rect.width, minimumSize.width)
        rect.size.height = max(rect.height, minimumSize.height)
        copy.storedFrame = RectValue(rect)
        copy.effect.opacity = min(max(copy.effect.opacity, 0.1), 1)
        return copy
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var regions: [BlurRegion]
    public init(regions: [BlurRegion] = []) { self.regions = regions }
}
