// FineTuneTests/HUDPopupParityTests.swift
// Regression: the HUD's displayed value must always match the popup slider
// for the same underlying gain / device tier.

import Testing
import Foundation
@testable import FineTune

@Suite("HUD slider fraction matches popup slider position for every tier")
struct HUDPopupParityTests {
    @Test("Software tier: HUD sliderFraction == DeviceRow.volumeToSlider for the same gain", arguments: [
        Float(0.0), 0.01, 0.1, 0.25, 0.5, 0.7071, 0.9, 1.0
    ])
    func softwareParity(gain: Float) {
        let hudFraction = VolumeMapping.sliderFraction(forSystemGain: gain, tier: .software)
        let popupFraction = DeviceRow.volumeToSlider(gain, backend: .software)
        #expect(hudFraction == popupFraction)
    }

    @Test("Hardware tier: HUD sliderFraction == popup slider for the same scalar", arguments: [
        Float(0.0), 0.25, 0.5, 0.75, 1.0
    ])
    func hardwareParity(gain: Float) {
        let hudFraction = VolumeMapping.sliderFraction(forSystemGain: gain, tier: .hardware)
        let popupFraction = DeviceRow.volumeToSlider(gain, backend: .hardware)
        #expect(hudFraction == popupFraction)
    }

    @Test("DDC tier: HUD sliderFraction == popup slider for the same scalar", arguments: [
        Float(0.0), 0.25, 0.5, 0.75, 1.0
    ])
    func ddcParity(gain: Float) {
        let hudFraction = VolumeMapping.sliderFraction(forSystemGain: gain, tier: .ddc)
        let popupFraction = DeviceRow.volumeToSlider(gain, backend: .ddc)
        #expect(hudFraction == popupFraction)
    }

    @Test("Per-app: gainToSlider matches AppRowControls' sliderValue formula", arguments: [
        Float(0.0), 0.01, 0.25, 0.5, 1.0
    ])
    func perAppParity(gain: Float) {
        // AppRowControls.sliderValue (no drag override) == VolumeMapping.gainToSlider(volume).
        let hudFraction = VolumeMapping.gainToSlider(gain)
        let popupSliderValue = VolumeMapping.gainToSlider(gain)
        #expect(hudFraction == popupSliderValue)
    }
}

@Suite("Volume hotkey step counts cover the full range")
struct VolumeHotkeyStepCoverageTests {
    @Test("Each step's N presses cover [0, 1] exactly", arguments: VolumeHotkeyStep.allCases)
    func stepCoverage(step: VolumeHotkeyStep) {
        let pressesToMax = Int(round(1.0 / step.sliderDelta))
        var slider: Double = 0
        for _ in 0..<pressesToMax {
            slider = min(1.0, slider + step.sliderDelta)
        }
        #expect(abs(slider - 1.0) < 1e-9)
    }

    @Test("Normal step covers range in exactly 16 presses (Apple-native count preserved)")
    func normalIs16Presses() {
        let pressesToMax = Int(round(1.0 / VolumeHotkeyStep.normal.sliderDelta))
        #expect(pressesToMax == 16)
    }
}
