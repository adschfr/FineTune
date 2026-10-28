// FineTune/Audio/CatchAll/CatchAllHarnessPanel.swift
//
// A floating panel for the catch-all harness: shows which step runs, whether a tone should
// be audible right now, counts down before each listening step and asks right after it
// what the user heard. Without it the user cannot tell which sound belonged to which step.

import AppKit
import Observation
import SwiftUI

@Observable
@MainActor
final class HarnessPanelModel {
    enum Expectation: Equatable {
        case info
        case audible
        case silent
    }

    var step = "Vorbereitung"
    var headline = "Catch-all-Messung startet gleich"
    var detail = "Bitte nichts abspielen, bis die Messung fertig ist."
    var expectation: Expectation = .info
    var countdown: Int?
    var isPlaying = false
    var question: String?
    var options: [String] = []
    var lines: [String] = []
    var isDone = false

    @ObservationIgnored fileprivate var answer: CheckedContinuation<String, Never>?

    func answered(_ option: String) {
        question = nil
        options = []
        answer?.resume(returning: option)
        answer = nil
    }
}

private struct HarnessPanelView: View {
    let model: HarnessPanelModel

    private var bannerColor: Color {
        switch model.expectation {
        case .info: .gray
        case .audible: .green
        case .silent: .red
        }
    }

    private var bannerText: String {
        switch (model.expectation, model.isPlaying) {
        case (.info, _): model.isPlaying ? "Messung läuft (leise Töne sind normal)" : "Messung"
        case (.audible, true): "JETZT läuft ein Ton: sollte HÖRBAR sein"
        case (.audible, false): "Gleich: Ton, der HÖRBAR sein sollte"
        case (.silent, true): "JETZT läuft ein Ton: sollte NICHT hörbar sein"
        case (.silent, false): "Gleich: Ton, der NICHT hörbar sein sollte"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.step).font(.caption).foregroundStyle(.secondary)
            Text(model.headline).font(.headline)
            Text(model.detail).font(.callout).fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(bannerText).font(.callout.bold()).foregroundStyle(.white)
                Spacer()
                if let countdown = model.countdown {
                    Text("\(countdown)").font(.title.monospacedDigit().bold()).foregroundStyle(.white)
                }
            }
            .padding(10)
            .background(bannerColor.opacity(model.isPlaying || model.countdown != nil ? 1 : 0.5),
                        in: RoundedRectangle(cornerRadius: 8))

            if let question = model.question {
                Text(question).font(.callout.bold())
                HStack {
                    ForEach(model.options, id: \.self) { option in
                        Button(option) { model.answered(option) }
                    }
                }
            }

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.lines.suffix(8).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 110)
        }
        .padding(14)
        .frame(width: 460)
    }
}

/// Owns the panel window. Shown on the screen with the menu bar, above other windows.
@MainActor
final class HarnessPanel {
    let model = HarnessPanelModel()
    private var panel: NSPanel?

    func show() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "FineTune Catch-all-Messung"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: HarnessPanelView(model: model))
        if let screen = NSScreen.screens.first {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - 480, y: frame.maxY - 20))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }

    func log(_ line: String) {
        model.lines.append(line)
    }

    /// Shows what comes next and counts down, so the user is listening when it starts.
    func announce(step: String, headline: String, detail: String, expectation: HarnessPanelModel.Expectation, seconds: Int = 3) async {
        model.step = step
        model.headline = headline
        model.detail = detail
        model.expectation = expectation
        model.isPlaying = false
        await count(down: seconds)
    }

    /// Counts down while a tone keeps playing, e.g. to the H9 kill.
    func countdown(_ headline: String, seconds: Int) async {
        model.headline = headline
        await count(down: seconds)
    }

    private func count(down seconds: Int) async {
        for remaining in stride(from: seconds, to: 0, by: -1) {
            model.countdown = remaining
            try? await Task.sleep(for: .seconds(1))
        }
        model.countdown = nil
    }

    func playing(_ isPlaying: Bool) {
        model.isPlaying = isPlaying
    }

    /// Asks right after a listening step and waits for the answer (at most 2 minutes).
    func ask(_ question: String, options: [String]) async -> String {
        model.isPlaying = false
        model.question = question
        model.options = options
        return await withCheckedContinuation { continuation in
            model.answer = continuation
            Task { @MainActor [weak model] in
                try? await Task.sleep(for: .seconds(120))
                if let model, model.answer != nil { model.answered("keine Antwort") }
            }
        }
    }

    func finish(summary: String) {
        model.step = "Fertig"
        model.headline = "Messung abgeschlossen"
        model.detail = summary
        model.expectation = .info
        model.isPlaying = false
        model.isDone = true
    }
}
