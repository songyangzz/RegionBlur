import CoreGraphics

public enum WindowOcclusion {
    public static func isFullyCovered(target: CGRect, by occluders: [CGRect]) -> Bool {
        var visible = [target.standardized]
        for occluder in occluders {
            visible = visible.flatMap { subtract(occluder.standardized, from: $0) }
            if visible.isEmpty { return true }
        }
        return false
    }

    private static func subtract(_ cover: CGRect, from rect: CGRect) -> [CGRect] {
        let intersection = rect.intersection(cover)
        guard !intersection.isNull, !intersection.isEmpty else { return [rect] }
        var pieces: [CGRect] = []
        if intersection.minY > rect.minY { pieces.append(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: intersection.minY - rect.minY)) }
        if intersection.maxY < rect.maxY { pieces.append(CGRect(x: rect.minX, y: intersection.maxY, width: rect.width, height: rect.maxY - intersection.maxY)) }
        if intersection.minX > rect.minX { pieces.append(CGRect(x: rect.minX, y: intersection.minY, width: intersection.minX - rect.minX, height: intersection.height)) }
        if intersection.maxX < rect.maxX { pieces.append(CGRect(x: intersection.maxX, y: intersection.minY, width: rect.maxX - intersection.maxX, height: intersection.height)) }
        return pieces.filter { $0.width > 0 && $0.height > 0 }
    }
}
