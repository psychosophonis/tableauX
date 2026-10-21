import CoreGraphics

/// How a video is fitted to its display.
public enum Scaling: String, Codable, CaseIterable {
    /// Whole frame visible; black bars if the shapes differ (letterbox/pillarbox).
    case fit
    /// Display covered; the overflow is cropped off, centred.
    case fill
}

public enum Placement {
    /// The single factor a video is scaled by on a display.
    ///
    /// Scaling is UNIFORM (the same factor on both axes), which is what keeps the
    /// aspect ratio: circles stay circles. Stretching a 16:9 image onto a 16:3
    /// region is NON-UNIFORM scaling, and it's what the old "one wide virtual
    /// display" setup did. Fit takes the smaller of the two axis ratios, so
    /// neither side overflows; fill takes the larger, so neither side falls short.
    ///
    /// The app draws with AVPlayerLayer's aspect gravity, which applies the same
    /// rule. This function exists so setup can show the factor before you play:
    /// "2×" for HD on a 4K screen is a clean pixel doubling, while something like
    /// "1.33×" warns that the file isn't at a size the screen divides evenly.
    public static func scale(video: CGSize, display: CGSize, scaling: Scaling) -> CGFloat {
        guard video.width > 0, video.height > 0 else { return 0 }
        let sx = display.width / video.width
        let sy = display.height / video.height
        return scaling == .fit ? min(sx, sy) : max(sx, sy)
    }
}
