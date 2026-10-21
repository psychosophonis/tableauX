import CoreGraphics

/// What the app needs to know about one connected display.
public struct DisplayInfo: Equatable {
    public let id: UInt32          // CGDirectDisplayID
    public let name: String
    public let frame: CGRect       // in macOS's global desktop coordinates (points)
    public let pixelSize: CGSize   // the display's real pixels, e.g. 3840 × 2160

    public init(id: UInt32, name: String, frame: CGRect, pixelSize: CGSize) {
        self.id = id; self.name = name; self.frame = frame; self.pixelSize = pixelSize
    }
}

public enum DisplayOrder {
    /// Numbers displays 1…N left to right, as arranged in System Settings → Displays.
    ///
    /// The macOS display list comes back in no guaranteed order (it can change
    /// between reboots or when a cable is reseated). Sorting by POSITION instead
    /// gives a CANONICAL ORDER: one derived from something a person can see and
    /// set (the Displays arrangement), so "panel 2" always means the middle screen
    /// whatever order macOS found them in. Ties on x (screens stacked vertically)
    /// fall back to y, then id, so the order is TOTAL: no two inputs compare
    /// equal, and the result never depends on the incoming order.
    public static func sorted(_ displays: [DisplayInfo]) -> [DisplayInfo] {
        displays.sorted {
            if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
            if $0.frame.minY != $1.frame.minY { return $0.frame.minY < $1.frame.minY }
            return $0.id < $1.id
        }
    }
}
