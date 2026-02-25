import Foundation

/// Audio EQ Cookbook biquad coefficient calculations
/// Reference: Robert Bristow-Johnson's Audio EQ Cookbook
enum BiquadMath {
    /// Standard Q for graphic EQ (overlapping bands)
    static let graphicEQQ: Double = 1.4

    /// Compute peaking EQ biquad coefficients
    /// Returns [b0, b1, b2, a1, a2] normalized by a0 for vDSP_biquad
    static func peakingEQCoefficients(
        frequency: Double,
        gainDB: Float,
        q: Double,
        sampleRate: Double
    ) -> [Double] {
        let A = pow(10.0, Double(gainDB) / 40.0)
        let omega = 2.0 * .pi * frequency / sampleRate
        let sinW = sin(omega)
        let cosW = cos(omega)
        let alpha = sinW / (2.0 * q)

        let b0 = 1.0 + alpha * A
        let b1 = -2.0 * cosW
        let b2 = 1.0 - alpha * A
        let a0 = 1.0 + alpha / A
        let a1 = -2.0 * cosW
        let a2 = 1.0 - alpha / A

        // Normalize by a0 for vDSP_biquad format
        // vDSP difference equation: y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]
        // Coefficients are passed as-is (vDSP internally subtracts a1/a2)
        return [
            b0 / a0,
            b1 / a0,
            b2 / a0,
            a1 / a0,
            a2 / a0
        ]
    }

    /// Compute low shelf biquad coefficients (RBJ cookbook)
    /// Returns [b0, b1, b2, a1, a2] normalized by a0 for vDSP_biquad
    static func lowShelfCoefficients(
        frequency: Double,
        gainDB: Float,
        q: Double,
        sampleRate: Double
    ) -> [Double] {
        let A = pow(10.0, Double(gainDB) / 40.0)
        let omega = 2.0 * .pi * frequency / sampleRate
        let sinW = sin(omega)
        let cosW = cos(omega)
        let alpha = sinW / (2.0 * q)
        let twoSqrtAAlpha = 2.0 * sqrt(A) * alpha

        let b0 = A * ((A + 1.0) - (A - 1.0) * cosW + twoSqrtAAlpha)
        let b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosW)
        let b2 = A * ((A + 1.0) - (A - 1.0) * cosW - twoSqrtAAlpha)
        let a0 = (A + 1.0) + (A - 1.0) * cosW + twoSqrtAAlpha
        let a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cosW)
        let a2 = (A + 1.0) + (A - 1.0) * cosW - twoSqrtAAlpha

        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }

    /// Compute high shelf biquad coefficients (RBJ cookbook)
    /// Returns [b0, b1, b2, a1, a2] normalized by a0 for vDSP_biquad
    static func highShelfCoefficients(
        frequency: Double,
        gainDB: Float,
        q: Double,
        sampleRate: Double
    ) -> [Double] {
        let A = pow(10.0, Double(gainDB) / 40.0)
        let omega = 2.0 * .pi * frequency / sampleRate
        let sinW = sin(omega)
        let cosW = cos(omega)
        let alpha = sinW / (2.0 * q)
        let twoSqrtAAlpha = 2.0 * sqrt(A) * alpha

        let b0 = A * ((A + 1.0) + (A - 1.0) * cosW + twoSqrtAAlpha)
        let b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosW)
        let b2 = A * ((A + 1.0) + (A - 1.0) * cosW - twoSqrtAAlpha)
        let a0 = (A + 1.0) - (A - 1.0) * cosW + twoSqrtAAlpha
        let a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cosW)
        let a2 = (A + 1.0) - (A - 1.0) * cosW - twoSqrtAAlpha

        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }

    /// Compute coefficients for AutoEQ filters (peaking, lowShelf, highShelf).
    /// Returns flat array of 5*N Doubles for vDSP_biquad_CreateSetup.
    static func coefficientsForAutoEQFilters(
        _ filters: [AutoEQFilter],
        sampleRate: Double
    ) -> [Double] {
        var allCoeffs: [Double] = []
        allCoeffs.reserveCapacity(filters.count * 5)

        for filter in filters {
            // Bypass filters at or above Nyquist
            if filter.frequency >= sampleRate / 2.0 {
                allCoeffs.append(contentsOf: [1.0, 0.0, 0.0, 0.0, 0.0])
                continue
            }

            let coeffs: [Double]
            switch filter.type {
            case .peaking:
                coeffs = peakingEQCoefficients(
                    frequency: filter.frequency, gainDB: filter.gainDB,
                    q: filter.q, sampleRate: sampleRate)
            case .lowShelf:
                coeffs = lowShelfCoefficients(
                    frequency: filter.frequency, gainDB: filter.gainDB,
                    q: filter.q, sampleRate: sampleRate)
            case .highShelf:
                coeffs = highShelfCoefficients(
                    frequency: filter.frequency, gainDB: filter.gainDB,
                    q: filter.q, sampleRate: sampleRate)
            }
            allCoeffs.append(contentsOf: coeffs)
        }

        return allCoeffs
    }

    /// Compute coefficients for all 10 bands
    /// Returns 50 Doubles: [band0: b0,b1,b2,a1,a2, band1: ..., ...]
    static func coefficientsForAllBands(
        gains: [Float],
        sampleRate: Double
    ) -> [Double] {
        precondition(gains.count == EQSettings.bandCount)

        var allCoeffs: [Double] = []
        allCoeffs.reserveCapacity(50)

        for (index, frequency) in EQSettings.frequencies.enumerated() {
            // Bands at or above Nyquist cannot exist in the signal — bypass with unity gain.
            // Without this guard, omega > pi produces negative alpha, yielding unstable
            // biquad coefficients (poles outside the unit circle) that cause exponentially
            // growing output heard as robotic/static distortion.
            if frequency >= sampleRate / 2.0 {
                allCoeffs.append(contentsOf: [1.0, 0.0, 0.0, 0.0, 0.0])
                continue
            }
            let bandCoeffs = peakingEQCoefficients(
                frequency: frequency,
                gainDB: gains[index],
                q: graphicEQQ,
                sampleRate: sampleRate
            )
            allCoeffs.append(contentsOf: bandCoeffs)
        }

        return allCoeffs
    }
}
