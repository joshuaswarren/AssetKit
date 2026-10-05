import Foundation

/// Icon Composer pre-render, following the RenderBox display list that IconRendering builds for
/// actool 27.0 (`renderedLegacyCompatibleIconWithConfiguration:forDeviceClass:`; recorded from the
/// framework, glass-lab/FINDINGS-recipe.md). Working space: Display P3, gamma-encoded,
/// premultiplied Float planes. Per group, back to front: colored or black shadow (blur 22.4,
/// offset +16/+16, plus-darker), backdrop blur 64 inside the shape (blur material), content
/// masked by the translucency shader, glow and two glass highlights (plus-lighter). Then the
/// chiclet rim overlay. Output: sRGB 8-bit BGRA.
enum GlassRender {
    static let n = 1024
    static let count = n * n

    struct Image {
        var r: [Float], g: [Float], b: [Float], a: [Float]
        init(fill r: Float = 0, _ g: Float = 0, _ b: Float = 0, _ a: Float = 0) {
            self.r = [Float](repeating: r, count: GlassRender.count)
            self.g = [Float](repeating: g, count: GlassRender.count)
            self.b = [Float](repeating: b, count: GlassRender.count)
            self.a = [Float](repeating: a, count: GlassRender.count)
        }
    }

    // MARK: color

    static func toLinear(_ c: Float) -> Float {
        let a = abs(c)
        let v = a <= 0.04045 ? a / 12.92 : powf((a + 0.055) / 1.055, 2.4)
        return c < 0 ? -v : v
    }

    static func toGamma(_ c: Float) -> Float {
        let a = abs(c)
        let v = a <= 0.0031308 ? a * 12.92 : 1.055 * powf(a, 1 / 2.4) - 0.055
        return c < 0 ? -v : v
    }

    static let srgbToP3: [Float] = [0.82259286, 0.17753395, 0, 0.03319952, 0.96678355, 0, 0.01708535, 0.07239572, 0.91030145]
    static let p3ToSRGB: [Float] = [1.22474527, -0.22490439, 0, -0.04205797, 1.04208095, 0, -0.01964227, -0.07865486, 1.09853720]

    static func convert(_ rgb: (Float, Float, Float), _ m: [Float]) -> (Float, Float, Float) {
        let l = (toLinear(rgb.0), toLinear(rgb.1), toLinear(rgb.2))
        return (toGamma(m[0] * l.0 + m[1] * l.1 + m[2] * l.2),
                toGamma(m[3] * l.0 + m[4] * l.1 + m[5] * l.2),
                toGamma(m[6] * l.0 + m[7] * l.1 + m[8] * l.2))
    }

    /// An Icon Composer color as P3 gamma components + alpha.
    static func p3(_ color: IconComposerCompiler.IconColor) -> (Float, Float, Float, Float) {
        let c = color.components.map(Float.init)
        switch color.colorSpaceID {
        case 2, 6: return (c[0], c[0], c[0], c.count > 1 ? c[1] : 1)
        case 3: return (c[0], c[1], c[2], c[3])
        default:
            let p = convert((c[0], c[1], c[2]), srgbToP3)
            return (p.0, p.1, p.2, c[3])
        }
    }

    // MARK: resampling and placement

    static func keys(_ x: Float) -> Float {
        let x = abs(x), a: Float = -0.5
        if x < 1 { return (a + 2) * x * x * x - (a + 3) * x * x + 1 }
        if x < 2 { return a * x * x * x - 5 * a * x * x + 8 * a * x - 4 * a }
        return 0
    }

    /// Cubic (Keys a=-0.5) resampling weights: for each output index, 4 (index, weight) taps.
    static func taps(input: Int, output: Int) -> [(Int, [Float])] {
        (0..<output).map { o in
            let x = (Float(o) + 0.5) * Float(input) / Float(output) - 0.5
            let lo = Int(x.rounded(.down)) - 1
            var w = (0..<4).map { keys(Float(lo + $0) - x) }
            let s = w.reduce(0, +)
            w = w.map { $0 / s }
            return (lo, w)
        }
    }

    /// Source image (straight sRGB 8-bit) -> premultiplied P3 planes resampled to `size`, placed
    /// on the canvas at `origin`.
    static func place(_ image: IconComposerCompiler.LoadedImage, size: (Int, Int), origin: (Int, Int)) -> Image {
        let sw = image.width, sh = image.height
        let dw = max(1, size.0), dh = max(1, size.1)
        var src = [[Float]](repeating: [Float](repeating: 0, count: sw * sh), count: 4)
        for i in 0..<(sw * sh) {
            let p = image.pixels[i]
            let a = Float(p.a) / 255
            guard a > 0 else { continue }
            let c = convert((Float(p.r) / 255, Float(p.g) / 255, Float(p.b) / 255), srgbToP3)
            src[0][i] = c.0 * a; src[1][i] = c.1 * a; src[2][i] = c.2 * a; src[3][i] = a
        }
        let tx = taps(input: sw, output: dw)
        let ty = taps(input: sh, output: dh)
        var out = Image()
        var row = [Float](repeating: 0, count: dh * sw)
        for ch in 0..<4 {
            for oy in 0..<dh {
                let (lo, wt) = ty[oy]
                for k in 0..<4 {
                    let sy = min(max(lo + k, 0), sh - 1), f = wt[k]
                    let base = sy * sw
                    if k == 0 {
                        for x in 0..<sw { row[oy * sw + x] = src[ch][base + x] * f }
                    } else {
                        for x in 0..<sw { row[oy * sw + x] += src[ch][base + x] * f }
                    }
                }
            }
            for oy in 0..<dh {
                let cy = origin.1 + oy
                guard cy >= 0, cy < n else { continue }
                for ox in 0..<dw {
                    let cx = origin.0 + ox
                    guard cx >= 0, cx < n else { continue }
                    let (lo, wt) = tx[ox]
                    var v: Float = 0
                    for k in 0..<4 { v += row[oy * sw + min(max(lo + k, 0), sw - 1)] * wt[k] }
                    switch ch {
                    case 0: out.r[cy * n + cx] = v
                    case 1: out.g[cy * n + cx] = v
                    case 2: out.b[cy * n + cx] = v
                    default: out.a[cy * n + cx] = v
                    }
                }
            }
        }
        return out
    }

    // MARK: compositing

    static func over(_ dst: inout Image, _ src: Image, mask: [Float]? = nil) {
        for i in 0..<count {
            let m = mask?[i] ?? 1
            let sa = src.a[i] * m
            guard sa != 0 else { continue }
            let k = 1 - sa
            dst.r[i] = src.r[i] * m + dst.r[i] * k
            dst.g[i] = src.g[i] * m + dst.g[i] * k
            dst.b[i] = src.b[i] * m + dst.b[i] * k
            dst.a[i] = sa + dst.a[i] * k
        }
    }

    static func plusLighterWhite(_ dst: inout Image, _ v: [Float], alpha: Float) {
        for i in 0..<count where v[i] != 0 {
            let s = v[i] * alpha
            dst.r[i] += s; dst.g[i] += s; dst.b[i] += s
            dst.a[i] = min(1, dst.a[i] + s)
        }
    }

    static func plusDarker(_ dst: inout Image, _ src: Image, alpha: Float) {
        for i in 0..<count where src.a[i] != 0 {
            let sa = src.a[i] * alpha, da = dst.a[i]
            let oa = min(1, sa + da)
            dst.r[i] = max(0, oa - ((da - dst.r[i]) + (sa - src.r[i] * alpha)))
            dst.g[i] = max(0, oa - ((da - dst.g[i]) + (sa - src.g[i] * alpha)))
            dst.b[i] = max(0, oa - ((da - dst.b[i]) + (sa - src.b[i] * alpha)))
            dst.a[i] = oa
        }
    }

    // MARK: blur

    /// Separable Gaussian (sigma = RenderBox blur radius), zero outside the canvas.
    static func gaussian(_ plane: [Float], sigma: Float) -> [Float] {
        let r = Int((4 * sigma).rounded(.up))
        var k = (-r...r).map { expf(-Float($0 * $0) / (2 * sigma * sigma)) }
        let s = k.reduce(0, +)
        k = k.map { $0 / s }
        var tmp = [Float](repeating: 0, count: count)
        var out = [Float](repeating: 0, count: count)
        for y in 0..<n {
            let base = y * n
            for x in 0..<n {
                let v = plane[base + x]
                guard v != 0 else { continue }
                let lo = max(0, x - r), hi = min(n - 1, x + r)
                for t in lo...hi { tmp[base + t] += v * k[t - x + r] }
            }
        }
        for y in 0..<n {
            let lo = max(0, y - r), hi = min(n - 1, y + r)
            for t in lo...hi {
                let f = k[t - y + r], src = y * n, dstBase = t * n
                for x in 0..<n { out[dstBase + x] += tmp[src + x] * f }
            }
        }
        return out
    }

    /// Three-pass box approximation of a Gaussian (backdrop material blur over smooth content).
    static func boxBlur(_ plane: [Float], sigma: Float) -> [Float] {
        // ponytail: 3 box passes approximate the radius-64 backdrop blur; exact Gaussian if a
        // textured backdrop ever shows the difference.
        let w = Int((sqrtf(12 * sigma * sigma / 3 + 1)).rounded(.down)) | 1
        let h = w / 2
        var cur = plane
        for _ in 0..<3 {
            var next = [Float](repeating: 0, count: count)
            for y in 0..<n {
                var acc: Float = 0
                let base = y * n
                for x in -h..<(n + h) {
                    if x + h < n, x + h >= 0 { acc += cur[base + x + h] }
                    if x >= 0, x < n { next[base + x] = acc / Float(w) }
                    if x - h >= 0, x - h < n { acc -= cur[base + x - h] }
                }
            }
            cur = next
            next = [Float](repeating: 0, count: count)
            for x in 0..<n {
                var acc: Float = 0
                for y in -h..<(n + h) {
                    if y + h < n, y + h >= 0 { acc += cur[(y + h) * n + x] }
                    if y >= 0, y < n { next[y * n + x] = acc / Float(w) }
                    if y - h >= 0, y - h < n { acc -= cur[(y - h) * n + x] }
                }
            }
            cur = next
        }
        return cur
    }

    // MARK: distance fields

    /// 1-D squared distance transform (Felzenszwalb & Huttenlocher).
    static func dt1(_ f: [Float]) -> [Float] {
        let m = f.count
        var d = [Float](repeating: 0, count: m), v = [Int](repeating: 0, count: m)
        var z = [Float](repeating: 0, count: m + 1)
        var k = 0
        z[0] = -.infinity; z[1] = .infinity
        for q in 1..<m {
            var s: Float
            repeat {
                let p = v[k]
                s = ((f[q] + Float(q * q)) - (f[p] + Float(p * p))) / Float(2 * q - 2 * p)
                if s <= z[k] { k -= 1 } else { break }
            } while k >= 0
            k += 1
            v[k] = q; z[k] = s; z[k + 1] = .infinity
        }
        k = 0
        for q in 0..<m {
            while z[k + 1] < Float(q) { k += 1 }
            let p = v[k]
            d[q] = Float((q - p) * (q - p)) + f[p]
        }
        return d
    }

    /// Euclidean distance from each pixel to the nearest pixel where `feature` is true.
    static func edt(_ feature: [Bool]) -> [Float] {
        let big: Float = 1e12
        var g = feature.map { $0 ? 0 : big }
        for x in 0..<n {
            let col = dt1((0..<n).map { g[$0 * n + x] })
            for y in 0..<n { g[y * n + x] = col[y] }
        }
        for y in 0..<n {
            let row = dt1(Array(g[(y * n)..<(y * n + n)]))
            for x in 0..<n { g[y * n + x] = row[x].squareRoot() }
        }
        return g
    }

    /// Signed distance (px, positive inside) of alpha >= 0.5, and the outward unit normal.
    static func sdf(_ alpha: [Float]) -> (d: [Float], nx: [Float], ny: [Float]) {
        let inside = alpha.map { $0 >= 0.5 }
        let din = edt(inside.map { !$0 }), dout = edt(inside)
        var d = [Float](repeating: 0, count: count)
        for i in 0..<count { d[i] = inside[i] ? din[i] - 0.5 : -(dout[i] - 0.5) }
        var nx = [Float](repeating: 0, count: count), ny = nx
        for y in 0..<n {
            for x in 0..<n {
                let i = y * n + x
                let gx = x == 0 ? d[i + 1] - d[i] : (x == n - 1 ? d[i] - d[i - 1] : (d[i + 1] - d[i - 1]) / 2)
                let gy = y == 0 ? d[i + n] - d[i] : (y == n - 1 ? d[i] - d[i - n] : (d[i + n] - d[i - n]) / 2)
                let m = max((gx * gx + gy * gy).squareRoot(), 1e-9)
                nx[i] = -gx / m; ny[i] = -gy / m
            }
        }
        return (d, nx, ny)
    }

    static func fwidth(_ v: [Float], _ i: Int, _ x: Int, _ y: Int) -> Float {
        let dx = x < n - 1 ? abs(v[i + 1] - v[i]) : 0
        let dy = y < n - 1 ? abs(v[i + n] - v[i]) : 0
        return dx + dy
    }

    static func sat(_ x: Float) -> Float { min(max(x, 0), 1) }

    // MARK: glass shaders (decoded from IconRendering's default.metallib)

    static func translucencyMask(_ d: [Float], translucency tr: Float, bounds: (Float, Float)) -> [Float] {
        let ob = (1 - tr, Float(1)), cb = (Float(0.61), 1 - 0.8 * tr), bw: Float = 25.8
        let t = d.map { sat($0 / bw) }
        var out = [Float](repeating: 1, count: count)
        for y in 0..<n {
            let s = sat((Float(y) + 0.5 - bounds.0) / bounds.1)
            let o1 = ob.1 + (ob.0 - ob.1) * s, o2 = cb.1 + (cb.0 - cb.1) * s
            for x in 0..<n {
                let i = y * n + x
                let o = min(max(o2 + (o1 - o2) * t[i], 0), 1)
                let sm = o * o * (3 - 2 * o)
                let fw = min(max(fwidth(t, i, x, y), 1.0 / 1024), 2) * 0.833
                let e = sat(t[i] / fw + 0.5)
                out[i] = 1 + (sm - 1) * e
            }
        }
        return out
    }

    static func glow(_ d: [Float], radius: Float = -42.38) -> [Float] {
        let u = d.map { -$0 / radius }
        var out = [Float](repeating: 0, count: count)
        for y in 0..<n {
            for x in 0..<n {
                let i = y * n + x
                let g = expf(-0.5 * u[i] * u[i])
                let fw = min(max(fwidth(u, i, x, y), 1.0 / 1024), 2) * 0.833
                out[i] = sat(u[i] / fw + 0.5) * g
            }
        }
        return out
    }

    static func highlight(_ d: [Float], _ nx: [Float], _ ny: [Float], threshold: Float, bias: Float,
                          light: (Float, Float)) -> [Float] {
        let width: Float = 12, falloff: Float = 0.8
        let xv = d.map { $0 - 6 }
        var out = [Float](repeating: 0, count: count)
        for y in 0..<n {
            for x in 0..<n {
                let i = y * n + x
                let xi = xv[i]
                guard xi > -2, xi < width + 2 else { continue }
                let fw = min(max(fwidth(xv, i, x, y), 1.0 / 1024), 2) * 0.833
                let a = sat((width - xi) / fw + 0.5) * sat(xi / fw + 0.5)
                let m = 1 - falloff * sat(xi / width)
                let nd = light.0 * nx[i] + light.1 * ny[i]
                let q = sat((nd - threshold) / max(1 - threshold, 1.0 / 1024))
                let den = max(1 + (1 - q) * bias, 1.0 / 1024)
                out[i] = m * a * q / den
            }
        }
        return out
    }

    // MARK: chiclet

    /// Signed distance to the continuous-corner rounded rect (r = 230.4) within 100 px of the
    /// canvas edge; +inf elsewhere (interior).
    static let chicletDistance: [Float] = {
        let r: Double = 230.4, s = Double(n)
        let k = [1.52866483, 1.08849323, 0.86840689, 0.63149883, 0.07491139, 0.37282401, 0.16905939]
        func P(_ a: Double, _ b: Double) -> (Double, Double) { (s - a * r, b * r) }
        func bez(_ p: [(Double, Double)]) -> [(Double, Double)] {
            (0..<16).map { j in
                let t = Double(j) / 16, u = 1 - t
                return (u * u * u * p[0].0 + 3 * u * u * t * p[1].0 + 3 * u * t * t * p[2].0 + t * t * t * p[3].0,
                        u * u * u * p[0].1 + 3 * u * u * t * p[1].1 + 3 * u * t * t * p[2].1 + t * t * t * p[3].1)
            }
        }
        let corner = bez([P(k[0], 0), P(k[1], 0), P(k[2], 0), P(k[3], k[4])])
            + bez([P(k[3], k[4]), P(k[5], k[6]), P(k[6], k[5]), P(k[4], k[3])])
            + bez([P(k[4], k[3]), (s, k[2] * r), (s, k[1] * r), (s, k[0] * r)])
        var poly: [(Double, Double)] = []
        for rot in 0..<4 {
            let th = Double(rot) * .pi / 2, c = s / 2
            for p in corner {
                let x = p.0 - c, y = p.1 - c
                poly.append((x * cos(th) - y * sin(th) + c, x * sin(th) + y * cos(th) + c))
            }
        }
        var out = [Float](repeating: .infinity, count: count)
        for py in 0..<n {
            for px in 0..<n {
                guard min(min(px, py), min(n - 1 - px, n - 1 - py)) < 100 else { continue }
                let qx = Double(px) + 0.5, qy = Double(py) + 0.5
                var best = Double.infinity, inside = false
                for i in 0..<poly.count {
                    let a = poly[i], b = poly[(i + 1) % poly.count]
                    if (a.1 > qy) != (b.1 > qy), qx < (b.0 - a.0) * (qy - a.1) / (b.1 - a.1) + a.0 { inside.toggle() }
                    let abx = b.0 - a.0, aby = b.1 - a.1
                    let t = max(0, min(1, ((qx - a.0) * abx + (qy - a.1) * aby) / max(abx * abx + aby * aby, 1e-12)))
                    let dx = qx - a.0 - t * abx, dy = qy - a.1 - t * aby
                    best = min(best, dx * dx + dy * dy)
                }
                out[py * n + px] = Float(inside ? best.squareRoot() : -best.squareRoot())
            }
        }
        return out
    }()

    static func rimTable(_ appearance: Appearance?) -> [Int8]? {
        let text: String
        switch appearance {
        case .dark: text = GlassRimTables.dark
        case .tinted: return nil
        default: text = GlassRimTables.light
        }
        return Data(base64Encoded: text).map { $0.map { Int8(bitPattern: $0) } }
    }

    /// Chiclet rim from the recorded display list (icr9d `010-renderImage.xml`), not a
    /// per-icon residual. Inner stroke and two conic strokes are a 44 px stroke inverse-clipped
    /// to the continuous rounded rect inset by 22. The border is an 8/3 px stroke, inverse-clipped
    /// by group images. Tinted draws none of this. System-light and system-dark still use the
    /// IceCubes residual table: this stroke model regresses those backgrounds.
    static let rimField: (stroke: [Float], border: [Float], specA: [Float], specB: [Float]) = {
        let specA: [Float] = [1, 0.975586, 0.903809, 0.787109, 0.630371, 0.438965, 0.220703, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.220703, 0.438965, 0.630371, 0.787109, 0.903809, 0.975586, 1]
        let specB: [Float] = [1, 0.966797, 0.868164, 0.708008, 0.492676, 0.230225, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.230225, 0.492676, 0.708008, 0.868164, 0.966797, 1]
        func conic(_ stops: [Float], _ start: Float, _ x: Int, _ y: Int) -> Float {
            var u = (atan2f(Float(y) + 0.5 - 512, Float(x) + 0.5 - 512) - start) / (2 * .pi)
            u -= u.rounded(.down)
            let f = u * Float(stops.count - 1)
            let i = min(Int(f), stops.count - 2)
            let t = f - Float(i)
            return stops[i] * (1 - t) + stops[i + 1] * t
        }
        var stroke = [Float](repeating: 0, count: count)
        var border = stroke, a = stroke, b = stroke
        let d = chicletDistance
        for i in 0..<count {
            let dist = d[i]
            guard dist > -24, dist < 24 else { continue }
            let y = i / n, x = i - y * n
            let cov = sat(22 - abs(dist) + 0.5)
            let band = min(cov, sat(22.5 - dist))
            stroke[i] = band
            if band > 0 {
                a[i] = conic(specA, -2.35619, x, y) * 0.6 * band
                b[i] = conic(specB, 0.785398, x, y) * 0.4 * band
            }
            border[i] = sat((Float(8) / 3) / 2 - abs(dist) + 0.5)
        }
        return (stroke, border, a, b)
    }()

    /// Working-space rim. Inner stroke is plus-lighter white 0.08; conic strokes are source-over
    /// of extended white 1.09961; border is source-over black 0.12 (light) or white 0.15 (dark).
    static func applyRim(_ canvas: inout Image, uncovered: [Float], dark: Bool) {
        let rim = rimField
        let borderAlpha: Float = dark ? 0.15 : 0.12
        let borderColor: Float = dark ? 1 : 0
        for i in 0..<count {
            let s = rim.stroke[i]
            if s > 0 {
                let add = s * 0.08
                canvas.r[i] += add; canvas.g[i] += add; canvas.b[i] += add
                canvas.a[i] = min(1, canvas.a[i] + add)
                for spec in [rim.specA[i], rim.specB[i]] where spec > 0 {
                    let k = 1 - spec, src = 1.09961 * spec
                    canvas.r[i] = src + canvas.r[i] * k
                    canvas.g[i] = src + canvas.g[i] * k
                    canvas.b[i] = src + canvas.b[i] * k
                    canvas.a[i] = spec + canvas.a[i] * k
                }
            }
            let bc = rim.border[i] * uncovered[i]
            if bc > 0 {
                let a = borderAlpha * bc, k = 1 - a, src = borderColor * a
                canvas.r[i] = src + canvas.r[i] * k
                canvas.g[i] = src + canvas.g[i] * k
                canvas.b[i] = src + canvas.b[i] * k
                canvas.a[i] = a + canvas.a[i] * k
            }
        }
    }


    // MARK: render

    static func render(model: IconComposerCompiler.IconModel, images: [String: IconComposerCompiler.LoadedImage],
                       appearance: Appearance?) -> [UInt8] {
        typealias C = IconComposerCompiler
        let tinted = appearance == .tinted
        let fillForRim = tinted ? nil : C.resolveFill(model.fills, appearance: appearance)
        var canvas = Image(fill: 0, 0, 0, 1)
        if let fill = fillForRim {
            let (top, bottom): (C.IconColor, C.IconColor)
            switch fill {
            case .solid(let c): (top, bottom) = (c, c)
            case .gradient(let a, let b): (top, bottom) = (a, b)
            }
            let c0 = p3(top), c1 = p3(bottom)
            for y in 0..<n {
                let t = sat((Float(y) + 0.5 - 102.4) / 819.2)
                let r = c0.0 + (c1.0 - c0.0) * t, g = c0.1 + (c1.1 - c0.1) * t, b = c0.2 + (c1.2 - c0.2) * t
                for x in 0..<n { canvas.r[y * n + x] = r; canvas.g[y * n + x] = g; canvas.b[y * n + x] = b }
            }
        }
        let glassAlphas: (Float, Float, Float) = appearance == nil || appearance == .light ? (0.03, 0.04, 0.2) : (0.03, 0.08, 0.3)
        var covered = [Float](repeating: 1, count: count)
        for group in model.groups.reversed() {
            var content = Image()
            var glassImage = Image()
            var bounds: (Float, Float) = (0, Float(n))
            var glass = false
            var minY = n, maxY = 0
            for layer in group.layers.reversed() {
                guard let image = images[layer.imageName] else { continue }
                let rect = C.placedRect(image: image, layer: layer, group: group)
                let (ox, oy, pw, ph) = (rect.ox, rect.oy, rect.w, rect.h)
                var placed = place(image, size: (pw, ph), origin: (ox, oy))
                if let fill = C.resolveFill(layer.fills, appearance: appearance) {
                    for y in 0..<n {
                        let t = sat((Float(y - oy) + 0.5) / Float(ph))
                        let c: (Float, Float, Float, Float)
                        switch fill {
                        case .solid(let s): c = p3(s)
                        case .gradient(let a, let b):
                            let p = p3(a), q = p3(b), e = t * t * (3 - 2 * t)
                            let al = p.3 + (q.3 - p.3) * e, k = 1 / max(al, 1e-6)
                            c = ((p.0 * p.3 + (q.0 * q.3 - p.0 * p.3) * e) * k, (p.1 * p.3 + (q.1 * q.3 - p.1 * p.3) * e) * k,
                                 (p.2 * p.3 + (q.2 * q.3 - p.2 * p.3) * e) * k, al)
                        }
                        for x in 0..<n {
                            let i = y * n + x
                            let a = placed.a[i] * c.3
                            placed.r[i] = c.0 * a; placed.g[i] = c.1 * a; placed.b[i] = c.2 * a; placed.a[i] = a
                        }
                    }
                }
                let opacity = C.resolveOpacity(layer.opacities, appearance: appearance)
                if opacity != 1 {
                    for i in 0..<count {
                        placed.r[i] *= opacity; placed.g[i] *= opacity
                        placed.b[i] *= opacity; placed.a[i] *= opacity
                    }
                }
                if tinted {
                    for i in 0..<count where placed.a[i] > 0 {
                        let v = 0.2126 * placed.r[i] + 0.7152 * placed.g[i] + 0.0722 * placed.b[i]
                        placed.r[i] = v; placed.g[i] = v; placed.b[i] = v
                    }
                }
                over(&content, placed)
                if layer.glass {
                    over(&glassImage, placed)
                    glass = true
                }
                minY = min(minY, oy)
                maxY = max(maxY, oy + ph)
            }
            if minY < maxY { let k: Float = 1026 / 1024; bounds = (Float(minY) * k, Float(maxY - minY) * k) }
            // shadow: the group image (or black) blurred 22.4 at +16/+16, plus-darker
            if group.shadowStyle != 0 {
                let colored = !tinted && group.shadowKind == "layer-color"
                var shadow = Image()
                for y in 16..<n {
                    for x in 16..<n {
                        let s = (y - 16) * n + (x - 16), d = y * n + x
                        shadow.a[d] = content.a[s]
                        if colored { shadow.r[d] = content.r[s]; shadow.g[d] = content.g[s]; shadow.b[d] = content.b[s] }
                    }
                }
                shadow.a = gaussian(shadow.a, sigma: 22.4)
                if colored {
                    shadow.r = gaussian(shadow.r, sigma: 22.4)
                    shadow.g = gaussian(shadow.g, sigma: 22.4)
                    shadow.b = gaussian(shadow.b, sigma: 22.4)
                }
                let alpha: Float = tinted ? 0.05 : (colored ? Float(group.shadowOpacity) * 0.5 : Float(group.shadowOpacity) * 0.1)
                plusDarker(&canvas, shadow, alpha: alpha)
            }
            let shape = sdf(content.a)
            if group.blurStrength > 0 {
                let r = boxBlur(canvas.r, sigma: 64), g = boxBlur(canvas.g, sigma: 64), b = boxBlur(canvas.b, sigma: 64)
                for i in 0..<count where shape.d[i] >= 0 { canvas.r[i] = r[i]; canvas.g[i] = g[i]; canvas.b[i] = b[i] }
            }
            let tr = tinted ? 0 : C.resolveTranslucency(group.translucency, appearance: appearance)
            over(&canvas, content, mask: tr > 0 ? translucencyMask(shape.d, translucency: tr, bounds: bounds) : nil)
            if glass {
                let field = sdf(glassImage.a)
                plusLighterWhite(&canvas, glow(field.d), alpha: glassAlphas.0)
                plusLighterWhite(&canvas, highlight(field.d, field.nx, field.ny, threshold: -1.01, bias: -1, light: (1, 0)),
                                 alpha: glassAlphas.1)
                plusLighterWhite(&canvas, highlight(field.d, field.nx, field.ny, threshold: -0.309017, bias: 0,
                                                    light: (-0.707107, -0.707107)), alpha: glassAlphas.2)
            }
            for i in 0..<count { covered[i] *= 1 - min(1, content.a[i]) }
        }
        let systemFill = C.presetFill(appearance == .dark ? "system-dark" : "system-light")
        let systemRim = !tinted && fillForRim == systemFill
        if appearance != .tinted, !systemRim { applyRim(&canvas, uncovered: covered, dark: appearance == .dark) }
        let rim = systemRim ? rimTable(appearance) : nil
        let dsq = chicletDistance
        var out = [UInt8](repeating: 255, count: count * 4)
        for y in 0..<n {
            let thetaRow = Float(y) + 0.5 - 512
            for x in 0..<n {
                let i = y * n + x
                let a = max(canvas.a[i], 1e-6)
                var c = convert((canvas.r[i] / a, canvas.g[i] / a, canvas.b[i] / a), p3ToSRGB)
                c = (c.0 * 255, c.1 * 255, c.2 * 255)
                if let rim, covered[i] > 0, dsq[i] > -48, dsq[i] < 24 {
                    let th = atan2f(thetaRow, Float(x) + 0.5 - 512) * 180 / .pi
                    let tb = min(max(Int((th + 180) / 2), 0), 179)
                    let db = min(max(Int(dsq[i].rounded(.down)) + 48, 0), 72)
                    let add = Float(rim[tb * 73 + db])
                    c = (c.0 + add, c.1 + add, c.2 + add)
                }
                func q(_ v: Float) -> UInt8 { UInt8(min(max(v, 0), 255).rounded()) }
                out[i * 4] = q(c.2); out[i * 4 + 1] = q(c.1); out[i * 4 + 2] = q(c.0)
            }
        }
        return out
    }
}
