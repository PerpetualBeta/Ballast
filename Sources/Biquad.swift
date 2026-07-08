import Foundation

/// Second-order IIR (biquad) coefficients, normalised so a0 = 1.
struct BiquadCoefficients {
    var b0: Double = 1, b1: Double = 0, b2: Double = 0
    var a1: Double = 0, a2: Double = 0
}

/// ITU-R BS.1770 "K-weighting" — the two-stage pre-filter EBU R128 loudness is
/// measured through. Stage 1 is a high-frequency shelf modelling the acoustic
/// effect of a head; stage 2 is a low-cut ("RLB") high-pass.
///
/// The standard only tabulates coefficients at 48 kHz. Rather than hardcode
/// that table (and so be wrong at 44.1 / 96 kHz), we keep the *filter's*
/// defining parameters — centre frequency, Q and shelf gain, straight from the
/// spec — and derive the biquad for the running sample rate with the RBJ
/// Audio-EQ-cookbook formulas. At 48 kHz this reproduces the published
/// coefficients to within rounding.
enum KWeighting {

    // BS.1770-4 filter parameters.
    private static let stage1CentreHz = 1681.9744509555319
    private static let stage1Q        = 0.7071752369554196
    private static let stage1GainDB   = 3.999843853973347

    private static let stage2CentreHz = 38.13547087613982
    private static let stage2Q        = 0.5003270373238773

    static func stage1(sampleRate: Double) -> BiquadCoefficients {
        highShelf(sampleRate: sampleRate, centreHz: stage1CentreHz, q: stage1Q, gainDB: stage1GainDB)
    }

    static func stage2(sampleRate: Double) -> BiquadCoefficients {
        highPass(sampleRate: sampleRate, centreHz: stage2CentreHz, q: stage2Q)
    }

    // MARK: RBJ Audio-EQ cookbook

    private static func highShelf(sampleRate: Double, centreHz: Double, q: Double, gainDB: Double) -> BiquadCoefficients {
        let a = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Double.pi * centreHz / sampleRate
        let cosw0 = cos(w0)
        let alpha = sin(w0) / (2.0 * q)
        let twoSqrtAAlpha = 2.0 * sqrt(a) * alpha

        let b0 =        a * ((a + 1) + (a - 1) * cosw0 + twoSqrtAAlpha)
        let b1 = -2.0 * a * ((a - 1) + (a + 1) * cosw0)
        let b2 =        a * ((a + 1) + (a - 1) * cosw0 - twoSqrtAAlpha)
        let a0 =            (a + 1) - (a - 1) * cosw0 + twoSqrtAAlpha
        let a1 =    2.0 *  ((a - 1) - (a + 1) * cosw0)
        let a2 =            (a + 1) - (a - 1) * cosw0 - twoSqrtAAlpha

        return BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    private static func highPass(sampleRate: Double, centreHz: Double, q: Double) -> BiquadCoefficients {
        let w0 = 2.0 * Double.pi * centreHz / sampleRate
        let cosw0 = cos(w0)
        let alpha = sin(w0) / (2.0 * q)

        let b0 =  (1 + cosw0) / 2
        let b1 = -(1 + cosw0)
        let b2 =  (1 + cosw0) / 2
        let a0 =   1 + alpha
        let a1 =  -2 * cosw0
        let a2 =   1 - alpha

        return BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }
}
