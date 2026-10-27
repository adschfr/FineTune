// FineTune/AppEntry.swift
import SwiftUI

/// Picks the app to run. The unit tests are hosted in this app; under XCTest the full
/// `FineTuneApp` must not start, or every test run would create process taps, request
/// TCC permissions, probe DDC, install the media-key tap and touch the user's settings.
@main
@MainActor
enum AppEntry {
    static func main() {
        if TestHost.isActive {
            TestHostApp.main()
        } else {
            FineTuneApp.main()
        }
    }
}

/// Detects a hosted test run. xcodebuild sets these variables for the host process of
/// both XCTest and Swift Testing bundles.
enum TestHost {
    static var isActive: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }
}

/// Minimal host for unit tests: no audio engine, no permission prompts, no status item.
private struct TestHostApp: App {
    var body: some Scene {
        Settings { EmptyView() }
    }
}
