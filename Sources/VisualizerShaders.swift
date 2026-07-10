import Foundation

/// Metal Shading Language for the visualiser, compiled at runtime.
/// Uniforms (buffer 0): u[0]=time u[1]=resW u[2]=resH u[3]=needleL u[4]=needleR
///   u[5]=beat u[6]=bandCount u[7]=waveCount u[8]=level u[9]=bandWaveCount
///   u[10]=spectrumBars u[11]=tint(0/1) u[12]=grooveClock (Dancer)
/// buffer(1)=spectrum, buffer(3)=peaks, buffer(4)=bandWaves,
/// buffer(5)=palette (3 rgba colours from the wallpaper, when tint=1).
enum VisualizerShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    vertex float4 viz_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        return float4(p * 2.0 - 1.0, 0.0, 1.0);
    }

    static inline float deg2rad(float d) { return d * 0.017453292519943295; }
    static inline float3 palC(device const float* p, int i) { return float3(p[i*4], p[i*4+1], p[i*4+2]); }
    static inline float hash(float2 p) {
        p = fract(p * float2(123.34, 345.45));
        p += dot(p, p + 34.345);
        return fract(p.x * p.y);
    }
    static inline float vnoise(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash(i), hash(i + float2(1,0)), u.x),
                   mix(hash(i + float2(0,1)), hash(i + float2(1,1)), u.x), u.y);
    }
    static inline float fbm(float2 p) {
        float v = 0.0, a = 0.5;
        for (int i = 0; i < 5; i++) { v += a * vnoise(p); p *= 2.0; a *= 0.5; }
        return v;
    }
    static inline float sdSeg(float2 p, float2 a, float2 b) {
        float2 pa = p - a, ba = b - a;
        float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        return length(pa - ba * h);
    }
    static inline float sdRoundBox(float2 p, float2 b, float r) {
        float2 q = abs(p) - b + r;
        return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
    }

    // --- Aurora: calm rising curtains filling the frame. ---
    fragment float4 viz_aurora(float4 pos [[position]],
        constant float* u [[buffer(0)]], device const float* spec [[buffer(1)]],
        device const float* pal [[buffer(5)]]) {
        float2 res = float2(u[1], u[2]);
        float2 uv = float2(pos.x / res.x, 1.0 - pos.y / res.y);
        float t = u[0] * 0.05, level = u[8], beat = u[5];
        uint bands = uint(u[6]);
        float2 p = float2(uv.x * 2.0, uv.y * 1.4);
        float warp = fbm(p * 0.7 + float2(t, -t * 0.6));
        float f = fbm(p + float2(warp * 0.9 + t * 0.5, warp * 0.5 - t * 0.2));
        float vert = pow(1.0 - uv.y, 0.55);
        float sm = spec[uint(clamp(uv.x, 0.0, 0.999) * float(bands))];
        float intensity = ((0.35 + 1.0 * f) * (0.40 + 0.75 * vert) * (0.60 + level * 1.0) + sm * 0.30 * vert) * 1.25;
        bool tint = u[11] > 0.5;
        float3 baseA = tint ? palC(pal, 0) : float3(0.10, 0.50, 0.38);
        float3 baseB = tint ? palC(pal, 2) : float3(0.36, 0.22, 0.62);
        float3 baseC = tint ? palC(pal, 1) : float3(0.10, 0.42, 0.72);
        float3 col = baseA;
        col = mix(col, baseB, smoothstep(0.40, 0.90, f));
        col = mix(col, baseC, smoothstep(0.0, 0.35, uv.x) * 0.35);
        col *= intensity;
        col += beat * 0.07 * float3(0.4, 0.7, 0.9);
        col = max(col, float3(0.02, 0.03, 0.05) * (1.2 - uv.y));
        return float4(col, 1.0);
    }

    // --- Spectrum: LED-segment wide bars with peak-hold caps. ---
    fragment float4 viz_spectrum(float4 pos [[position]],
        constant float* u [[buffer(0)]], device const float* spec [[buffer(1)]],
        device const float* peaks [[buffer(3)]], device const float* pal [[buffer(5)]]) {
        float2 res = float2(u[1], u[2]);
        float2 uv = float2(pos.x / res.x, 1.0 - pos.y / res.y);
        uint barCount = uint(u[10]);
        float fb = uv.x * float(barCount);
        uint bar = uint(clamp(fb, 0.0, float(barCount) - 1.0));
        float bgap = smoothstep(0.0, 0.10, fract(fb)) * smoothstep(1.0, 0.90, fract(fb));
        uint bands = uint(u[6]);
        uint lo = bar * bands / barCount, hi = max(lo + 1, (bar + 1) * bands / barCount);
        float mag = 0.0, pk = 0.0;
        for (uint i = lo; i < hi; i++) { mag = max(mag, spec[i]); pk = max(pk, peaks[i]); }
        float segN = 18.0;
        float segIdx = floor(uv.y * segN);
        float sgap = smoothstep(0.0, 0.16, fract(uv.y * segN)) * smoothstep(1.0, 0.84, fract(uv.y * segN));
        float segLevel = (segIdx + 0.5) / segN;
        bool tint = u[11] > 0.5;
        // The standing bar stays calm (green, or the two low palette tones);
        // amber/red (or the palette accent) is reserved for the peak-hold caps,
        // getting redder the louder the peak.
        float3 bodyLo = tint ? palC(pal, 0) : float3(0.10, 0.55, 0.16);
        float3 bodyHi = tint ? palC(pal, 1) : float3(0.32, 0.92, 0.28);
        float3 body = mix(bodyLo, bodyHi, segLevel);
        float3 cap = tint ? palC(pal, 2)
                          : mix(float3(0.95, 0.62, 0.10), float3(0.96, 0.13, 0.06), smoothstep(0.45, 0.92, pk));
        float lit = segLevel <= mag ? 1.0 : 0.10;
        bool isPeak = abs(segIdx - floor(pk * segN - 0.001)) < 0.5;
        float3 col = (isPeak ? cap : body * lit) * bgap * sgap;
        col += float3(0.015, 0.02, 0.025);
        return float4(col, 1.0);
    }

    // --- Oscilloscope: smooth AA curves, stacked per band. ---
    fragment float4 viz_scope(float4 pos [[position]],
        constant float* u [[buffer(0)]], device const float* bw [[buffer(4)]],
        device const float* pal [[buffer(5)]]) {
        float2 res = float2(u[1], u[2]);
        float2 uv = float2(pos.x / res.x, 1.0 - pos.y / res.y);
        uint n = uint(u[7]), nb = uint(u[9]);
        float3 col = float3(0.02, 0.03, 0.035);
        float3 pl[3] = { float3(0.96, 0.55, 0.20), float3(0.20, 0.92, 0.52), float3(0.34, 0.72, 1.0) };
        if (u[11] > 0.5) { pl[0] = palC(pal, 0); pl[1] = palC(pal, 1); pl[2] = palC(pal, 2); }
        for (uint band = 0; band < nb; band++) {
            float baseY = (float(band) + 0.5) / float(nb);
            float fx = clamp(uv.x, 0.0, 0.9999) * float(n - 1);
            uint i0 = uint(fx), i1 = min(i0 + 1, n - 1);
            float s = mix(bw[band * n + i0], bw[band * n + i1], fract(fx));
            float slope = abs(bw[band * n + i1] - bw[band * n + i0]) * float(n) / res.x * res.y;
            float amp = 0.85 / float(nb);
            float thick = 0.006 * (1.0 + slope * 0.12);
            col += pl[band] * smoothstep(thick, 0.0, abs(uv.y - (baseY + s * amp * 0.5)));
        }
        return float4(col, 1.0);
    }

    // --- VU: rectangular meters that fill the window, contained needle. ---
    static inline float4 vuMeter(float2 d, float hw, float hh, float needle) {
        float corner = min(hw, hh) * 0.12;
        float bezT = min(hw, hh) * 0.09;
        float face = smoothstep(0.004, -0.004, sdRoundBox(d, float2(hw, hh), corner));
        float bez  = clamp(smoothstep(0.004, -0.004, sdRoundBox(d, float2(hw + bezT, hh + bezT), corner * 1.3)) - face, 0.0, 1.0);
        float glow = 1.0 - smoothstep(0.0, hh * 1.4, length(d - float2(0.0, -hh * 0.5)));
        float3 col = mix(float3(0.80, 0.68, 0.44), float3(1.0, 0.95, 0.74), glow);
        float2 pivot = float2(0.0, -hh * 0.82);
        float2 rel = d - pivot;
        float rr = length(rel), ang = atan2(rel.y, rel.x);
        float arcR = hh * 1.30, lw = hh * 0.012;
        float aL = deg2rad(125.0), aR = deg2rad(55.0), zero = deg2rad(80.0);
        bool inSweep = ang > aR && ang < aL, red = ang < zero;
        col = mix(col, float3(0.12, 0.09, 0.06), smoothstep(lw * 1.6, lw * 0.4, abs(rr - arcR)) * ((inSweep && !red) ? 1.0 : 0.0));
        col = mix(col, float3(0.80, 0.10, 0.05), smoothstep(lw * 2.6, lw * 0.6, abs(rr - arcR)) * ((inSweep && red) ? 1.0 : 0.0));
        for (int i = 0; i <= 11; i++) {
            float ta = mix(aL, aR, float(i) / 11.0);
            float2 dir = float2(cos(ta), sin(ta));
            float len = (i % 3 == 0) ? hh * 0.14 : hh * 0.08;
            float2 tOut = pivot + dir * arcR, tIn = pivot + dir * (arcR - len);
            col = mix(col, (ta < zero) ? float3(0.80, 0.10, 0.05) : float3(0.10, 0.08, 0.05),
                      smoothstep(lw * 1.2, 0.0, sdSeg(d, tIn, tOut)));
        }
        float na = mix(aL, aR, clamp(needle, 0.0, 1.0));
        float2 tip = pivot + float2(cos(na), sin(na)) * arcR;
        col = mix(col, float3(0.08, 0.06, 0.05), smoothstep(lw * 1.6, lw * 0.4, sdSeg(d, pivot, tip)));
        col = mix(col, float3(0.16, 0.15, 0.15), smoothstep(hh * 0.09, hh * 0.07, length(d - float2(hw * 0.68, hh * 0.62))));
        float3 bezCol = mix(float3(0.55, 0.42, 0.20), float3(0.26, 0.19, 0.09), smoothstep(hh, -hh, d.y));
        return float4(mix(bezCol, col, face), clamp(face + bez, 0.0, 1.0));
    }
    fragment float4 viz_vu(float4 pos [[position]], constant float* u [[buffer(0)]]) {
        float2 res = float2(u[1], u[2]);
        float2 uv = float2(pos.x / res.x, 1.0 - pos.y / res.y);
        float aspect = res.x / res.y;
        float tex = fbm(float2(uv.x * 90.0, uv.y * 90.0));
        float3 col = (float3(0.09, 0.09, 0.12) + (tex - 0.5) * 0.03) * (0.85 + 0.2 * uv.y);
        float2 P = float2(uv.x * aspect, uv.y);
        float margin = 0.06, gap = 0.05;
        float meterW = (aspect - 2.0 * margin - gap) * 0.5;
        float hw = meterW * 0.5, hh = (1.0 - 2.0 * margin) * 0.5;
        float cxL = margin + hw, cxR = margin + meterW + gap + hw;
        float4 l = vuMeter(P - float2(cxL, 0.5), hw, hh, u[3]); col = mix(col, l.rgb, l.a);
        float4 r = vuMeter(P - float2(cxR, 0.5), hw, hh, u[4]); col = mix(col, r.rgb, r.a);
        return float4(col, 1.0);
    }

    // --- Dancer: a mirrored thin-bar spectrum over a cinematic, music-reactive
    //     backlit haze with a swaying silhouette — "a figure in the light". ---
    fragment float4 viz_dancer(float4 pos [[position]],
        constant float* u [[buffer(0)]], device const float* spec [[buffer(1)]],
        device const float* pal [[buffer(5)]]) {
        float2 res = float2(u[1], u[2]);
        float2 uv = float2(pos.x / res.x, 1.0 - pos.y / res.y);
        float t = u[0], beat = u[5], level = u[8];
        bool tint = u[11] > 0.5;

        // Volumetric haze + a backlight glow (spotlight high and to the left)
        // that drifts and pulses with the music.
        float hz = fbm(uv * float2(2.6, 1.9) + float2(t * 0.04, -t * 0.03));
        float2 lp = (uv - float2(0.34, 0.74)) * float2(1.2, 1.0);
        float g = exp(-dot(lp, lp) * 2.8);
        float light = g * (0.5 + 0.7 * hz) * (0.65 + level * 0.9) + 0.05 * hz;
        light += beat * 0.22 * g;
        // a soft diagonal shaft falling from the upper-left spotlight
        light += exp(-abs((uv.x - 0.34) - (0.74 - uv.y) * 0.25) * 6.0) * (0.10 + 0.16 * hz) * smoothstep(-0.1, 0.85, uv.y);

        // A soft hint of a dancer — head, torso, arms and a flowing skirt —
        // moving organically to the music (slow smooth harmonics + the
        // *smoothed* energy; no jittery beat term). A gentle occlusion of the
        // backlight, never a hard shape.
        float e = clamp(level * 1.4, 0.0, 1.0);
        float dp = u[12];                                       // music-paced groove clock (smooth)
        float aspect = res.x / res.y;
        // A floor of ~6 abstract vapour presences — each a cheap gaussian around
        // its own wavering, drifting spine. ONE shared smoke texture for the
        // whole room (not one per dancer) keeps it light: six exp()s + a single
        // fbm per pixel, so no fan-spinning load.
        float smoke = fbm(float2(uv.x * aspect, uv.y) * float2(5.5, 3.5) + float2(0.0, -dp * 0.4));
        float total = 0.0;
        for (int i = 0; i < 6; i++) {
            float fi = float(i);
            float bx = 0.5 + (fi - 2.5) * 0.11;                 // spread across the stage
            float cxi = bx + 0.06 * sin(dp * (0.13 + 0.025 * fi) + fi * 1.7);
            float x = (uv.x - cxi) * aspect;
            float centre = sin(uv.y * 3.2 + dp * 0.8 + fi * 2.0) * (0.04 + 0.03 * e)
                         + sin(uv.y * 6.5 - dp * 1.1 + fi) * 0.018;
            float width = 0.05 + 0.018 * e + 0.012 * sin(dp * 0.6 + fi);
            float top = 0.46 + 0.12 * sin(fi * 1.7);            // varied heights
            float env = smoothstep(0.0, 0.15, uv.y) * (1.0 - smoothstep(top, top + 0.42, uv.y));
            float d = x - centre;
            total += exp(-(d * d) / (width * width) * 1.6) * env;
        }
        float dens = clamp(total, 0.0, 1.0) * (0.35 + 0.95 * smoke);

        float3 warm = tint ? (palC(pal, 1) * 1.4 + 0.25) : float3(1.0, 0.95, 0.88);
        float3 col = warm * light;
        col *= 1.0 - dens * 0.42;                               // soft, textured occlusion — vapour
        float3 room = tint ? palC(pal, 0) * 0.10 : float3(0.02, 0.025, 0.035);
        col = max(col, room);
        float vig = 1.0 - smoothstep(0.55, 1.15, length((uv - 0.5) * float2(1.15, 1.0)));
        col *= 0.45 + 0.55 * vig;

        // Mirrored thin-bar spectrum + baseline (a solid line and a dotted line).
        float specW = 0.66, axisY = 0.5;
        float sx = (uv.x - (0.5 - specW * 0.5)) / specW;
        float lineW = 1.6 / res.y;
        float3 ink = tint ? (palC(pal, 2) * 1.3 + 0.2) : float3(1.0);
        if (sx >= 0.0 && sx <= 1.0) {
            float dy = uv.y - axisY;
            float barCount = 48.0;
            float fb = sx * barCount;
            float barGap = smoothstep(0.0, 0.30, fract(fb)) * smoothstep(1.0, 0.70, fract(fb));
            uint bands = uint(u[6]);
            // The top ~1/8 of the bands (~7.5–15 kHz) carries almost no musical
            // energy, so the last few bars mapped there sat permanently dead — the
            // "inactive bars on the right". Spread all the bars across only the
            // lower, energy-bearing bands so every bar responds to the music.
            uint activeBands = (bands * 7u) / 8u;
            uint bar = uint(clamp(fb, 0.0, barCount - 1.0));
            uint lo = bar * activeBands / uint(barCount);
            uint hi = max(lo + 1u, (bar + 1u) * activeBands / uint(barCount));
            float mag = 0.0;
            for (uint i = lo; i < hi; i++) mag = max(mag, spec[i]);
            mag = pow(mag, 0.9);
            float upH = mag * 0.15, downH = mag * 0.19;
            float aa = lineW * 1.5;
            float barMask = (dy >= 0.0) ? barGap * smoothstep(aa, 0.0, dy - upH)
                                        : barGap * smoothstep(aa, 0.0, (-dy) - downH);
            float solid = smoothstep(lineW * 1.5, 0.0, abs(dy)) * 0.9;
            float dots = step(0.55, fract(uv.x * 64.0));
            float dotted = smoothstep(lineW * 1.5, 0.0, abs(uv.y - (axisY - 0.018))) * dots * 0.85;
            float sInk = clamp(max(barMask, max(solid, dotted)), 0.0, 1.0);
            col = mix(col, ink, sInk);
        }
        return float4(col, 1.0);
    }
    """
}
