import CoreVideo

// Detects black bars baked into the picture — a 4:3 show pillarboxed inside a
// 16:9 frame, a scope film letterboxed in 16:9 — so fit/fill can work on the
// real picture instead of the full coded frame. Without it, fit on a display
// whose aspect differs from the frame adds a second set of bars, and fill
// fills the window with the frame but the picture inside it still doesn't.
//
// Detection reads a coarse grid of the luma plane on the CPU (a few thousand
// samples, ~0.1 ms) twice a second. The crop it reports only ever moves in
// the safe direction once established: it can shrink (content found inside
// what looked like a bar — a wider shot, a logo) but never grow, so a dark
// scene can't eat into the picture. Bars must be symmetric, at least 1% of
// the frame, and agree across three consecutive samples before any crop is
// applied.
struct BlackBarCrop: Equatable {
    // Luma pixels trimmed from each side, in coded (unrotated) orientation.
    var left = 0, right = 0, top = 0, bottom = 0
    var isEmpty: Bool { left == 0 && right == 0 && top == 0 && bottom == 0 }
}

final class BlackBarDetector {
    private(set) var crop = BlackBarCrop()
    private var frameSize = (0, 0)
    private var pending: [BlackBarCrop] = []
    private var established = false
    private var lastSampleTime = -Double.infinity
    private static let interval = 0.5
    private static let confirmations = 3

    func reset() {
        crop = BlackBarCrop()
        frameSize = (0, 0)
        pending.removeAll()
        established = false
        lastSampleTime = -.infinity
    }

    // Returns true when `crop` changed. `now` is any monotonic clock in seconds.
    func observe(_ pixelBuffer: CVPixelBuffer, fullRange: Bool, now: Double) -> Bool {
        let w = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let h = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        if frameSize != (w, h) {
            // New geometry (mid-stream resolution change): start over.
            reset()
            frameSize = (w, h)
        }
        guard now - lastSampleTime >= Self.interval else { return false }
        lastSampleTime = now
        guard let raw = Self.measure(pixelBuffer, width: w, height: h, fullRange: fullRange) else {
            return false
        }
        let old = crop
        if established {
            // Shrink-only: real content further out on any side wins, kept
            // symmetric. Any frame qualifies — a dark or lopsided one only
            // ever shows bars at least as wide, which min() ignores.
            let side = Self.evenSliver(min(crop.left, raw.left, raw.right), of: w)
            let vert = Self.evenSliver(min(crop.top, raw.top, raw.bottom), of: h)
            crop = BlackBarCrop(left: side, right: side, top: vert, bottom: vert)
        } else if let sample = Self.trustworthy(raw, width: w, height: h) {
            let tol = max(4, max(w, h) / 200)
            if let first = pending.first,
               abs(first.left - sample.left) > tol || abs(first.top - sample.top) > tol {
                pending.removeAll()
            }
            pending.append(sample)
            if pending.count >= Self.confirmations {
                crop = BlackBarCrop(left: pending.map(\.left).min()!, right: pending.map(\.right).min()!,
                                    top: pending.map(\.top).min()!, bottom: pending.map(\.bottom).min()!)
                established = true
                pending.removeAll()
            }
        } else {
            pending.removeAll()   // the agreement run must be consecutive
        }
        return crop != old
    }

    // One frame's raw per-side black extents.
    private static func measure(_ pb: CVPixelBuffer, width w: Int, height h: Int,
                                fullRange: Bool) -> BlackBarCrop? {
        guard w >= 64, h >= 64, CVPixelBufferGetPlaneCount(pb) >= 1 else { return nil }
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        // 8-bit planes are one byte per sample; 10/16-bit are two bytes,
        // MSB-aligned little-endian, so the high byte is the 8-bit value.
        let bytesPerSample = rowBytes >= w * 2 ? 2 : 1
        let p = base.assumingMemoryBound(to: UInt8.self)
        @inline(__always) func luma(_ x: Int, _ y: Int) -> Int {
            Int(p[y * rowBytes + x * bytesPerSample + (bytesPerSample - 1)])
        }
        // Video-range black is 16; allow encoder noise/ringing above it.
        let threshold = (fullRange ? 0 : 16) + 12
        let steps = 96

        // A line counts as picture when more than 1/32 of its samples are
        // above black: one hot pixel of noise doesn't, a dim real edge does.
        func columnHasPicture(_ x: Int) -> Bool {
            var bright = 0
            for i in 0..<steps where luma(x, (i * 2 + 1) * h / (steps * 2)) > threshold {
                bright += 1
                if bright > steps / 32 { return true }
            }
            return false
        }
        func rowHasPicture(_ y: Int) -> Bool {
            var bright = 0
            for i in 0..<steps where luma((i * 2 + 1) * w / (steps * 2), y) > threshold {
                bright += 1
                if bright > steps / 32 { return true }
            }
            return false
        }
        // Coarse-to-fine: step in by 2 px until picture is found.
        var left = 0;   while left < w / 2, !columnHasPicture(left) { left += 2 }
        var right = 0;  while right < w / 2, !columnHasPicture(w - 1 - right) { right += 2 }
        var top = 0;    while top < h / 2, !rowHasPicture(top) { top += 2 }
        var bottom = 0; while bottom < h / 2, !rowHasPicture(h - 1 - bottom) { bottom += 2 }

        return BlackBarCrop(left: left, right: right, top: top, bottom: bottom)
    }

    // A frame good enough to establish a crop from: picture covers at least
    // half of each axis (not a fade or title card) and the bars are centred
    // (a lopsided "bar" is the dark side of the shot, not letterboxing).
    private static func trustworthy(_ raw: BlackBarCrop, width w: Int, height h: Int) -> BlackBarCrop? {
        guard w - raw.left - raw.right >= w / 2, h - raw.top - raw.bottom >= h / 2 else { return nil }
        guard abs(raw.left - raw.right) <= max(4, w / 100),
              abs(raw.top - raw.bottom) <= max(4, h / 100) else { return nil }
        let side = evenSliver(min(raw.left, raw.right), of: w)
        let vert = evenSliver(min(raw.top, raw.bottom), of: h)
        return BlackBarCrop(left: side, right: side, top: vert, bottom: vert)
    }

    // Slivers under 1% (edge junk, overscan lines) aren't worth cropping —
    // they'd only cost 1:1 pixel copies their exactness. Even pixels keep
    // 4:2:0 chroma aligned.
    private static func evenSliver(_ bar: Int, of extent: Int) -> Int {
        bar >= extent / 100 ? bar & ~1 : 0
    }
}
