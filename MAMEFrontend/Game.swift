import Foundation

/// A single MAME machine (arcade game, console/computer driver, etc.).
struct Game: Identifiable, Hashable {
    /// MAME short name, e.g. "mslug". This is what you pass to the binary.
    let shortName: String

    /// Human-readable description, e.g. "Metal Slug - Super Vehicle-001".
    let description: String

    /// True when a matching ROM archive exists on disk but this MAME build
    /// didn't list the short name in `-listfull`.
    let isUnknown: Bool

    /// Parent short name if this machine is a clone (from `-listclones`);
    /// nil for parents and standalone machines.
    let parent: String?

    /// Most recent launch time. `.distantPast` means "never played". Stored as a
    /// non-optional Date so it can drive column sorting via a plain key path.
    var lastPlayed: Date

    /// Release year from `-listxml`. 0 means unknown / not fetched yet. Kept as
    /// a plain Int so it sorts directly; filled in progressively after load.
    var year: Int

    var isClone: Bool { parent != nil }
    var hasBeenPlayed: Bool { lastPlayed != .distantPast }
    var hasYear: Bool { year > 0 }

    /// Case-folded title used as the sort key for the Game column so ordering is
    /// case-insensitive.
    var sortTitle: String { description.lowercased() }

    var id: String { shortName }

    init(shortName: String,
         description: String,
         isUnknown: Bool = false,
         parent: String? = nil,
         lastPlayed: Date = .distantPast,
         year: Int = 0) {
        self.shortName = shortName
        self.description = description
        self.isUnknown = isUnknown
        self.parent = parent
        self.lastPlayed = lastPlayed
        self.year = year
    }
}
