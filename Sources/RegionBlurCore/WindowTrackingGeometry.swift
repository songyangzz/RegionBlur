import CoreGraphics

public enum WindowTrackingGeometry {
    public static func trackedFrame(windowFrame: CGRect, overlayFrame: CGRect, resizesToWindow: Bool) -> CGRect {
        guard resizesToWindow else { return overlayFrame }
        return windowFrame
    }
}
