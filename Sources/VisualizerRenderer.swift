import MetalKit
import Accelerate

enum VisualizerMode: String, CaseIterable {
    case aurora, spectrum, oscilloscope, vu, nowplaying

    var displayName: String {
        switch self {
        case .aurora:       return "Aurora"
        case .spectrum:     return "Spectrum"
        case .oscilloscope: return "Oscilloscope"
        case .vu:           return "VU Meters"
        case .nowplaying:   return "Now Playing"
        }
    }
    /// Shader modes render in the MTKView; vu / nowplaying are AppKit/SwiftUI views.
    var isShader: Bool {
        switch self {
        case .aurora, .spectrum, .oscilloscope: return true
        case .vu, .nowplaying:                  return false
        }
    }
    var fragmentFunction: String {
        switch self {
        case .aurora:       return "viz_aurora"
        case .spectrum:     return "viz_spectrum"
        case .oscilloscope: return "viz_scope"
        case .vu, .nowplaying: return ""
        }
    }
}

/// Drives an MTKView: derives an FFT spectrum (with peak-hold), a beat estimate,
/// ballistic VU needle positions, and per-band oscilloscope waveforms from the
/// shared audio feed each frame, then renders the selected mode.
final class VisualizerRenderer: NSObject, MTKViewDelegate {

    private static let fftSize = 2048
    private static let bandCount = 128
    private static let waveCount = 512
    private static let bandWaveCount = 3          // low / mid / high

    var mode: VisualizerMode

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipelines: [VisualizerMode: MTLRenderPipelineState] = [:]

    private let uniformBuf: MTLBuffer
    private let spectrumBuf: MTLBuffer
    private let waveBuf: MTLBuffer
    private let peakBuf: MTLBuffer
    private let bandWaveBuf: MTLBuffer
    private let palBuf: MTLBuffer

    // vDSP / analysis
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var hann = [Float](repeating: 0, count: fftSize)
    private var samples = [Float](repeating: 0, count: fftSize)
    private var windowed = [Float](repeating: 0, count: fftSize)
    private var realp = [Float](repeating: 0, count: fftSize / 2)
    private var imagp = [Float](repeating: 0, count: fftSize / 2)
    private var mags = [Float](repeating: 0, count: fftSize / 2)
    private var bands = [Float](repeating: 0, count: bandCount)
    private var peaks = [Float](repeating: 0, count: bandCount)
    private var bandWaves = [Float](repeating: 0, count: bandWaveCount * waveCount)
    private var rawBands = [Float](repeating: 0, count: bandCount)
    private var autoMax: Float = 1e-4
    private var bassAvg: Float = 0
    private var levelSmooth: Float = 0
    // VU needle ballistics (spring-damper): position + velocity per channel.
    private var needlePosL: Float = 0, needleVelL: Float = 0
    private var needlePosR: Float = 0, needleVelR: Float = 0
    private var startTime = CFAbsoluteTimeGetCurrent()

    init?(mode: VisualizerMode) {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return nil }
        device = dev
        queue = q
        self.mode = mode
        log2n = vDSP_Length(log2(Float(Self.fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        fftSetup = setup

        func buf(_ count: Int) -> MTLBuffer? {
            dev.makeBuffer(length: count * MemoryLayout<Float>.stride, options: .storageModeShared)
        }
        guard let u = buf(12), let sp = buf(Self.bandCount), let wv = buf(Self.waveCount),
              let pk = buf(Self.bandCount), let bw = buf(Self.bandWaveCount * Self.waveCount),
              let pl = buf(12)
        else { return nil }
        uniformBuf = u; spectrumBuf = sp; waveBuf = wv; peakBuf = pk; bandWaveBuf = bw; palBuf = pl

        super.init()
        vDSP_hann_window(&hann, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))

        do {
            let library = try dev.makeLibrary(source: VisualizerShaders.source, options: nil)
            let vfn = library.makeFunction(name: "viz_vertex")
            for m in VisualizerMode.allCases where m.isShader {
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = vfn
                desc.fragmentFunction = library.makeFunction(name: m.fragmentFunction)
                desc.colorAttachments[0].pixelFormat = .bgra8Unorm
                pipelines[m] = try dev.makeRenderPipelineState(descriptor: desc)
            }
        } catch {
            blLog("visualiser: shader compile/pipeline failed: \(error)")
            return nil
        }
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Wallpaper palette (low / mid / accent). nil -> built-in colours.
    var colours: [SIMD3<Float>]? { didSet { uploadPalette() } }
    private func uploadPalette() {
        guard let c = colours, c.count >= 3 else { return }
        palBuf.contents().withMemoryRebound(to: Float.self, capacity: 12) { p in
            for i in 0..<3 { p[i*4] = c[i].x; p[i*4+1] = c[i].y; p[i*4+2] = c[i].z; p[i*4+3] = 1 }
        }
    }

    // MARK: Analysis

    private func analyse() {
        samples.withUnsafeMutableBufferPointer { VisualizerFeed.shared.latest(into: $0.baseAddress!, count: Self.fftSize) }
        vDSP_vmul(samples, 1, hann, 1, &windowed, 1, vDSP_Length(Self.fftSize))

        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wb in
                    wb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.fftSize / 2) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(Self.fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(Self.fftSize / 2))
            }
        }

        // Log-spaced bands, magnitude -> dB -> 0..1, fast-attack / slow-decay,
        // plus a slow-falling peak-hold.
        let bins = Self.fftSize / 2
        let minBin = 2.0, maxBin = Double(bins) * 0.70   // ignore the near-Nyquist noise floor
        let octaveSpan = log2(maxBin / minBin)
        var frameMax: Float = 1e-6
        for b in 0..<Self.bandCount {
            let f0 = pow(maxBin / minBin, Double(b) / Double(Self.bandCount)) * minBin
            let f1 = pow(maxBin / minBin, Double(b + 1) / Double(Self.bandCount)) * minBin
            let lo = max(2, Int(f0)), hi = max(lo + 1, min(bins, Int(f1)))
            var peak: Float = 0
            for i in lo..<hi { peak = max(peak, mags[i]) }
            // Linear magnitude, tilted +4.5 dB/octave to counter music's natural
            // bass-heavy spectrum (derived from log-frequency, not a fixed fudge).
            let octaves = Double(b) / Double(Self.bandCount) * octaveSpan
            let tilt = min(Float(24), Float(pow(10.0, (4.5 / 20.0) * octaves)))
            let m = sqrt(peak) * tilt
            rawBands[b] = m
            frameMax = max(frameMax, m)
        }
        // Auto-gain: normalise to a slow-decaying peak (with headroom) so the
        // bars use the full height and dance, rather than pegging against a
        // fixed reference. The scale is derived from the signal, not hardcoded.
        autoMax = max(autoMax * 0.99, frameMax)
        let ref = autoMax * 1.15
        for b in 0..<Self.bandCount {
            let norm = min(1, pow(rawBands[b] / ref, 0.6))
            bands[b] += (norm - bands[b]) * (norm > bands[b] ? 0.5 : 0.12)
            peaks[b] = bands[b] > peaks[b] ? bands[b] : max(bands[b], peaks[b] - 0.006)
        }

        // Beat from bass energy.
        var bass: Float = 0
        for b in 0..<12 { bass += bands[b] }
        bass /= 12
        bassAvg += (bass - bassAvg) * 0.05
        let beat = max(0, min(1, (bass - bassAvg) / (bassAvg + 0.05)))

        // Overall level for Aurora.
        let overall = min(1, (VisualizerFeed.shared.levelL + VisualizerFeed.shared.levelR) * 0.5 * 3)
        levelSmooth += (overall - levelSmooth) * 0.10

        // VU needle ballistics — spring toward the target with damping (momentum,
        // ~mechanical rise time, slight overshoot).
        let dt: Float = 1.0 / 60.0, k: Float = 120, c: Float = 16
        let tL = min(1, VisualizerFeed.shared.levelL * 3.5)
        let tR = min(1, VisualizerFeed.shared.levelR * 3.5)
        needleVelL += (k * (tL - needlePosL) - c * needleVelL) * dt
        needlePosL = max(0, min(1.15, needlePosL + needleVelL * dt))
        needleVelR += (k * (tR - needlePosR) - c * needleVelR) * dt
        needlePosR = max(0, min(1.15, needlePosR + needleVelR * dt))

        // Per-band oscilloscope waveforms (cascaded one-poles: low / mid / high).
        var lp1: Float = 0, lp2: Float = 0
        let step = Self.fftSize / Self.waveCount
        var wi = 0
        for i in 0..<Self.fftSize {
            let x = samples[i]
            lp1 += 0.02 * (x - lp1)
            lp2 += 0.20 * (x - lp2)
            if i % step == 0 && wi < Self.waveCount {
                bandWaves[0 * Self.waveCount + wi] = max(-1, min(1, lp1 * 2.5))
                bandWaves[1 * Self.waveCount + wi] = max(-1, min(1, (lp2 - lp1) * 3.5))
                bandWaves[2 * Self.waveCount + wi] = max(-1, min(1, (x - lp2) * 4.5))
                wi += 1
            }
        }

        // Upload.
        copy(bands, to: spectrumBuf, count: Self.bandCount)
        copy(peaks, to: peakBuf, count: Self.bandCount)
        copy(bandWaves, to: bandWaveBuf, count: Self.bandWaveCount * Self.waveCount)
        let t = Float(CFAbsoluteTimeGetCurrent() - startTime)
        uniformBuf.contents().withMemoryRebound(to: Float.self, capacity: 12) { p in
            p[0] = t
            p[3] = needlePosL
            p[4] = needlePosR
            p[5] = beat
            p[6] = Float(Self.bandCount)
            p[7] = Float(Self.waveCount)
            p[8] = levelSmooth
            p[9] = Float(Self.bandWaveCount)
            p[10] = 20                              // spectrum: wide LED bars
            p[11] = (colours != nil) ? 1 : 0        // wallpaper tint on/off
        }
    }

    private func copy(_ src: [Float], to buffer: MTLBuffer, count: Int) {
        buffer.contents().withMemoryRebound(to: Float.self, capacity: count) { p in
            src.withUnsafeBufferPointer { s in p.update(from: s.baseAddress!, count: count) }
        }
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline = pipelines[mode],
              let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)
        else { return }

        analyse()
        let size = view.drawableSize
        uniformBuf.contents().withMemoryRebound(to: Float.self, capacity: 12) { p in
            p[1] = Float(size.width); p[2] = Float(size.height)
        }

        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBuffer(uniformBuf, offset: 0, index: 0)
        enc.setFragmentBuffer(spectrumBuf, offset: 0, index: 1)
        enc.setFragmentBuffer(waveBuf, offset: 0, index: 2)
        enc.setFragmentBuffer(peakBuf, offset: 0, index: 3)
        enc.setFragmentBuffer(bandWaveBuf, offset: 0, index: 4)
        enc.setFragmentBuffer(palBuf, offset: 0, index: 5)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
