import CoreAudio

/// Helpers to move float32 audio between Core Audio's `AudioBufferList`
/// (interleaved *or* non-interleaved) and the ring's interleaved storage.
/// All are allocation-free and safe to call from an IO thread.
enum AudioBufferSupport {

    /// Frame count an output buffer list expects, given the channel count.
    static func outputFrameCount(_ abl: UnsafeMutablePointer<AudioBufferList>, channels: Int) -> Int {
        let bufs = UnsafeMutableAudioBufferListPointer(abl)
        guard bufs.count > 0 else { return 0 }
        if bufs.count == 1 {
            let ch = max(1, Int(bufs[0].mNumberChannels))
            return Int(bufs[0].mDataByteSize) / (MemoryLayout<Float>.size * ch)
        }
        return Int(bufs[0].mDataByteSize) / MemoryLayout<Float>.size
    }

    /// Copy an input buffer list into interleaved `dst` ([frames × channels]).
    /// Returns the number of frames copied.
    static func interleave(_ abl: UnsafePointer<AudioBufferList>,
                           into dst: UnsafeMutablePointer<Float>,
                           channels: Int, maxFrames: Int) -> Int {
        let bufs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        guard bufs.count > 0 else { return 0 }

        if bufs.count == 1 {
            guard let data = bufs[0].mData else { return 0 }
            let srcCh = max(1, Int(bufs[0].mNumberChannels))
            let frames = min(maxFrames, Int(bufs[0].mDataByteSize) / (MemoryLayout<Float>.size * srcCh))
            let p = data.assumingMemoryBound(to: Float.self)
            if srcCh == channels {
                memcpy(dst, p, frames * channels * MemoryLayout<Float>.size)
            } else {
                for f in 0..<frames {
                    for c in 0..<channels {
                        dst[f * channels + c] = p[f * srcCh + min(c, srcCh - 1)]
                    }
                }
            }
            return frames
        }

        // Non-interleaved: one buffer per channel.
        let n = min(channels, bufs.count)
        let frames = min(maxFrames, Int(bufs[0].mDataByteSize) / MemoryLayout<Float>.size)
        for c in 0..<channels {
            let srcIdx = min(c, n - 1)
            guard let d = bufs[srcIdx].mData?.assumingMemoryBound(to: Float.self) else {
                for f in 0..<frames { dst[f * channels + c] = 0 }
                continue
            }
            for f in 0..<frames { dst[f * channels + c] = d[f] }
        }
        return frames
    }

    /// Write interleaved `src` ([frames × channels]) into an output buffer
    /// list, zero-filling anything beyond `frames`.
    static func deinterleave(_ src: UnsafePointer<Float>, frames: Int, channels: Int,
                             into abl: UnsafeMutablePointer<AudioBufferList>) {
        let bufs = UnsafeMutableAudioBufferListPointer(abl)
        guard bufs.count > 0 else { return }

        if bufs.count == 1 {
            guard let data = bufs[0].mData else { return }
            let dstCh = max(1, Int(bufs[0].mNumberChannels))
            let cap = Int(bufs[0].mDataByteSize) / (MemoryLayout<Float>.size * dstCh)
            let f = min(frames, cap)
            let p = data.assumingMemoryBound(to: Float.self)
            if dstCh == channels {
                memcpy(p, src, f * channels * MemoryLayout<Float>.size)
            } else {
                for i in 0..<f {
                    for c in 0..<dstCh { p[i * dstCh + c] = src[i * channels + min(c, channels - 1)] }
                }
            }
            if f < cap {
                memset(p + f * dstCh, 0, (cap - f) * dstCh * MemoryLayout<Float>.size)
            }
            return
        }

        // Non-interleaved: one buffer per channel.
        let cap = Int(bufs[0].mDataByteSize) / MemoryLayout<Float>.size
        let f = min(frames, cap)
        for c in 0..<bufs.count {
            guard let d = bufs[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let srcCh = min(c, channels - 1)
            for i in 0..<f { d[i] = src[i * channels + srcCh] }
            if f < cap { for i in f..<cap { d[i] = 0 } }
        }
    }

    /// Largest absolute sample in an interleaved buffer.
    static func peak(_ buf: UnsafePointer<Float>, count: Int) -> Float {
        var peak: Float = 0
        var i = 0
        while i < count { let a = abs(buf[i]); if a > peak { peak = a }; i += 1 }
        return peak
    }
}
