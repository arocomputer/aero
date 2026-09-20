import AppKit

/// Sizes of the strip's items. The proportions come from the reference design, scaled up to sit in the
/// system's regular 52pt toolbar instead of its 44pt one.
enum StripMetrics {
    static let topLift: CGFloat = 6
    static let itemHeight: CGFloat = 30
    static let pillWidth: CGFloat = 208
    static let pinWidth: CGFloat = 32
    static let arrowSize: CGFloat = 28
    static let gap: CGFloat = 3
    static let radius: CGFloat = 10
    static let titleFont = NSFont.systemFont(ofSize: 13)
    static let monogramFont = NSFont.systemFont(ofSize: 13, weight: .medium)
}
