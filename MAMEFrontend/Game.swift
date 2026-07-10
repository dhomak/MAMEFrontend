import Foundation

/// A single MAME machine (arcade game, console/computer driver, etc.).
struct Game: Identifiable, Hashable {
    let shortName: String
    let description: String
    let isUnknown: Bool
    let parent: String?

    var lastPlayed: Date
    var year: Int
    let genre: String
    var manufacturer: String
    var status: String        // driver status: good / imperfect / preliminary / "" (unknown)
    var isNonGame: Bool       // BIOS / device / mechanical / computer-console system
    var requiresDisk: Bool    // needs a CHD
    var diskPresent: Bool     // the required CHD(s) were found on disk

    // Precomputed once at construction so filtering/sorting never re-allocates.
    let sortTitle: String   // lowercased description (sort key)
    let searchKey: String   // lowercased "description shortName" (search haystack)
    let category: String    // top-level genre category (filter key)

    var isClone: Bool { parent != nil }
    var hasBeenPlayed: Bool { lastPlayed != .distantPast }
    var hasYear: Bool { year > 0 }
    /// Unknown status counts as working so nothing hides before metadata loads.
    var isWorking: Bool { status != "preliminary" }

    var id: String { shortName }

    init(shortName: String,
         description: String,
         isUnknown: Bool = false,
         parent: String? = nil,
         lastPlayed: Date = .distantPast,
         year: Int = 0,
         genre: String = "",
         manufacturer: String = "",
         status: String = "",
         isNonGame: Bool = false,
         requiresDisk: Bool = false,
         diskPresent: Bool = false) {
        self.shortName = shortName
        self.description = description
        self.isUnknown = isUnknown
        self.parent = parent
        self.lastPlayed = lastPlayed
        self.year = year
        self.genre = genre
        self.manufacturer = manufacturer
        self.status = status
        self.isNonGame = isNonGame
        self.requiresDisk = requiresDisk
        self.diskPresent = diskPresent

        self.sortTitle = description.lowercased()
        self.searchKey = (description + " " + shortName).lowercased()
        if genre.isEmpty {
            self.category = ""
        } else {
            self.category = genre.split(separator: "/").first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? genre
        }
    }
}
