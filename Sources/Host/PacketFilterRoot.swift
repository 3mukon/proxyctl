enum PacketFilterRoot {
    private static let appleScrub = "scrub-anchor \"com.apple/*\" all fragment reassemble"
    private static let appleFilter = "anchor \"com.apple/*\" all"

    static func withAppleDefaults(adding rule: String) -> String {
        // Normalization must precede both filter anchors.
        [appleScrub, rule, appleFilter].joined(separator: "\n")
    }

    static func adding(_ rule: String, to baseline: String) -> String? {
        switch baseline {
        case "":
            return rule
        case appleFilter:
            return rule + "\n" + appleFilter
        case appleScrub + "\n" + appleFilter:
            return withAppleDefaults(adding: rule)
        default:
            return nil
        }
    }
}
