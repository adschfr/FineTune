// FineTune/Models/VolumeMapping.swift
import Foundation

/// Utility for converting between slider position (0-1) and audio gain (0-1).
/// Square-law (x²) curve: more control at low volumes for per-app mixing.
/// Percentage displays slider position, not raw gain.
/// Boost is handled separately per-app, not in this mapping.
enum VolumeMapping {
    /// Convert slider position to gain using square-law curve.
    static func sliderToGain(_ slider: Double) -> Float {
        if slider <= 0 { return 0 }
        let t = min(slider, 1.0)
        return Float(t * t)
    }

    /// Convert gain to slider position using inverse square-law (sqrt).
    static func gainToSlider(_ gain: Float) -> Double {
        if gain <= 0 { return 0 }
        return Double(sqrt(min(gain, 1.0)))
    }
}
