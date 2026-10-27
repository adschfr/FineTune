// FineTuneTests/AutoEQTestSupport.swift
import Foundation
@testable import FineTune

extension AutoEQProfileManager {
    /// A manager for engine tests: no catalog download from GitHub and no access to the
    /// user's AutoEQ folders in Application Support.
    static func isolated() -> AutoEQProfileManager {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FineTuneTests-AutoEQ-\(UUID().uuidString)")
        return AutoEQProfileManager(loader: AutoEQProfileLoader(directory: directory), loadCatalog: false)
    }
}
