// FineTune/Audio/AutoEQProfileManager.swift
import Foundation
import os

/// Search result from `AutoEQProfileManager.search()`.
struct AutoEQSearchResult {
    let profiles: [AutoEQProfile]
    let totalCount: Int
}

/// Manages the in-memory catalog of AutoEQ headphone correction profiles.
/// File I/O is delegated to `AutoEQProfileLoader`.
@Observable
@MainActor
final class AutoEQProfileManager {
    private(set) var profiles: [String: AutoEQProfile] = [:]
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "AutoEQProfileManager")
    private let loader: AutoEQProfileLoader

    /// Pre-sorted profile list for fast search.
    private var sortedProfiles: [AutoEQProfile] = []

    /// Normalized names for fuzzy search (parallel array with sortedProfiles).
    /// Lowercased with all non-alphanumeric characters stripped.
    private var normalizedNames: [String] = []

    init(loader: AutoEQProfileLoader = AutoEQProfileLoader()) {
        self.loader = loader

        // Imported profiles are small — load synchronously
        let imported = loader.loadImportedProfiles()
        for profile in imported {
            profiles[profile.id] = profile
        }
        rebuildSortedProfiles()

        // Bundled JSON (~4MB) is loaded off the main thread to avoid blocking launch
        Task { @MainActor in
            let bundled = await loader.loadBundledProfiles()
            for profile in bundled {
                self.profiles[profile.id] = profile
            }
            self.rebuildSortedProfiles()
        }
    }

    // MARK: - Import / Delete

    /// Import a ParametricEQ.txt file. Copies to app support and adds to catalog.
    func importProfile(from url: URL, name: String) -> AutoEQProfile? {
        guard let profile = loader.importProfile(from: url, name: name) else { return nil }
        profiles[profile.id] = profile
        rebuildSortedProfiles()
        return profile
    }

    /// Delete an imported profile from disk and catalog.
    func deleteImportedProfile(id: String) {
        guard let profile = profiles[id], profile.source == .imported else { return }
        profiles.removeValue(forKey: id)
        rebuildSortedProfiles()
        loader.deleteProfileFiles(id: id)
        logger.info("Deleted imported profile: \(profile.name)")
    }

    // MARK: - Search

    private func rebuildSortedProfiles() {
        sortedProfiles = profiles.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        normalizedNames = sortedProfiles.map { Self.normalize($0.name) }
    }

    /// Fuzzy search across profile names with relevance ranking.
    ///
    /// Scoring tiers:
    /// - **Tier 1 (100-250):** Exact substring match (bonus for prefix/exact/shorter name)
    /// - **Tier 2 (50-99):** Normalized substring match (spaces/punctuation stripped)
    /// - **Tier 3 (1-49):** Token-based fuzzy match with Levenshtein edit distance
    ///
    /// Returns up to `limit` results sorted by relevance. Empty query returns nothing.
    func search(query: String, limit: Int = 50) -> AutoEQSearchResult {
        guard !query.isEmpty else { return AutoEQSearchResult(profiles: [], totalCount: 0) }

        let loweredQuery = query.lowercased()
        let normalizedQuery = Self.normalize(query)

        var scored: [(index: Int, score: Int)] = []
        scored.reserveCapacity(200)

        for i in 0..<sortedProfiles.count {
            let loweredName = sortedProfiles[i].name.lowercased()
            let normalizedName = normalizedNames[i]

            let score = Self.matchScore(
                loweredQuery: loweredQuery,
                normalizedQuery: normalizedQuery,
                loweredName: loweredName,
                normalizedName: normalizedName
            )

            if score > 0 {
                scored.append((index: i, score: score))
            }
        }

        // Sort by descending score, then alphabetically for ties
        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return sortedProfiles[$0.index].name < sortedProfiles[$1.index].name
        }

        let totalCount = scored.count
        let limitedResults = scored.prefix(limit).map { sortedProfiles[$0.index] }

        return AutoEQSearchResult(profiles: Array(limitedResults), totalCount: totalCount)
    }

    /// Look up a profile by ID.
    func profile(for id: String) -> AutoEQProfile? {
        profiles[id]
    }

    // MARK: - Scoring

    private static func matchScore(
        loweredQuery: String,
        normalizedQuery: String,
        loweredName: String,
        normalizedName: String
    ) -> Int {
        // Tier 1: Exact substring in original name (case-insensitive)
        if loweredName.contains(loweredQuery) {
            var score = 100
            if loweredName.hasPrefix(loweredQuery) { score += 50 }
            if loweredName == loweredQuery { score += 100 }
            // Prefer shorter names (closer match)
            score += max(0, 50 - loweredName.count)
            return score
        }

        // Tier 2: Normalized substring (space/punctuation tolerance)
        if !normalizedQuery.isEmpty && normalizedName.contains(normalizedQuery) {
            var score = 50
            if normalizedName.hasPrefix(normalizedQuery) { score += 25 }
            score += max(0, 25 - normalizedName.count)
            return score
        }

        // Tier 3: Token-based fuzzy match
        let queryTokens = loweredQuery.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !queryTokens.isEmpty else { return 0 }

        var totalTokenScore = 0
        for token in queryTokens {
            let tokenScore = bestTokenMatch(token: token, in: loweredName)
            if tokenScore == 0 { return 0 } // All tokens must match
            totalTokenScore += tokenScore
        }

        return min(49, totalTokenScore / queryTokens.count)
    }

    /// Find the best fuzzy match for a single token within a name.
    private static func bestTokenMatch(token: String, in name: String) -> Int {
        // First check substring match
        if name.contains(token) { return 40 }

        // Fuzzy: check edit distance against name tokens
        let nameTokens = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map(String.init)
        let maxAllowedDistance = token.count <= 4 ? 1 : 2

        var bestScore = 0
        for nameToken in nameTokens {
            let distance = editDistance(token, nameToken.lowercased())
            if distance <= maxAllowedDistance {
                let score = max(1, 30 - distance * 10)
                bestScore = max(bestScore, score)
            }
        }
        return bestScore
    }

    /// Levenshtein edit distance. O(n*m) but tokens are short (typically < 15 chars).
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count

        if m == 0 { return n }
        if n == 0 { return m }
        // Early exit for trivially different lengths
        if abs(m - n) > 2 { return max(m, n) }

        var prev = Array(0...n)
        var curr = Array(repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                if aChars[i - 1] == bChars[j - 1] {
                    curr[j] = prev[j - 1]
                } else {
                    curr[j] = 1 + min(prev[j - 1], prev[j], curr[j - 1])
                }
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }

    // MARK: - Normalization

    /// Strip non-alphanumeric characters and lowercase.
    /// "Sennheiser HD 600" → "sennheiserhd600"
    private static func normalize(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for char in string.unicodeScalars {
            if CharacterSet.alphanumerics.contains(char) {
                result.append(Character(char))
            }
        }
        return result.lowercased()
    }
}
