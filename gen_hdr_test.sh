#!/usr/bin/env bash
# Generates a 4K HDR PQ test video: 10 full-width horizontal bands at known
# nit levels (50, 100, 200, 400, 600, 800, 1000, 1200, 1400, 1600), BT.2100
# PQ encoded with HDR10 metadata.

set -euo pipefail

OUTPUT="${1:-test_pattern_hdr.mp4}"

if ! command -v ffmpeg &>/dev/null; then
    echo "ffmpeg required: brew install ffmpeg" >&2
    exit 1
fi

if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx265; then
    echo "ffmpeg needs libx265 for HDR10 output." >&2
    exit 1
fi

TMP_DIR=$(mktemp -d -t mfhdr)
trap 'rm -rf "$TMP_DIR"' EXIT
PNG_PATH="$TMP_DIR/hdr.png"
SWIFT_PATH="$TMP_DIR/gen.swift"

cat > "$SWIFT_PATH" << 'SWIFT'
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import AppKit

let outputPath = CommandLine.arguments[1]
let W = 3840
let H = 2160

// SMPTE ST 2084 (PQ) OETF: linear luminance in nits → normalized [0, 1].
func pqEncode(nits: Double) -> Double {
    let Lp = max(min(nits / 10000.0, 1.0), 0.0)
    let m1 = 2610.0 / 16384.0
    let m2 = 2523.0 * 128.0 / 4096.0
    let c1 = 3424.0 / 4096.0
    let c2 = 2413.0 * 32.0 / 4096.0
    let c3 = 2392.0 * 32.0 / 4096.0
    let LpM1 = pow(Lp, m1)
    return pow((c1 + c2 * LpM1) / (1 + c3 * LpM1), m2)
}

let bands: [Double] = [50, 100, 200, 400, 600, 800, 1000, 1200, 1400, 1600]
let bandH = H / bands.count // 216 px per band

let bytesPerPixel = 6 // 16-bit RGB
let rowBytes = W * bytesPerPixel
var bytes = [UInt8](repeating: 0, count: H * rowBytes)

func writePQ(_ off: Int, _ v: UInt16) {
    let lo = UInt8(v & 0xFF)
    let hi = UInt8(v >> 8)
    bytes[off]     = lo; bytes[off + 1] = hi
    bytes[off + 2] = lo; bytes[off + 3] = hi
    bytes[off + 4] = lo; bytes[off + 5] = hi
}

// Fill bands
for (i, nits) in bands.enumerated() {
    let pq = pqEncode(nits: nits)
    let v = UInt16(min(max(pq * 65535.0, 0), 65535).rounded())
    let yTop = i * bandH
    let yBot = (i == bands.count - 1) ? H : (i + 1) * bandH
    for y in yTop..<yBot {
        for x in 0..<W {
            writePQ(y * rowBytes + x * bytesPerPixel, v)
        }
    }
}

// Build label mask via a grayscale CGContext, then composite at per-band
// contrast brightness (dim labels on bright bands, bright labels on dim bands).
let maskBytesPerRow = W
var mask = [UInt8](repeating: 0, count: H * maskBytesPerRow)
mask.withUnsafeMutableBytes { buf in
    guard let base = buf.baseAddress else { return }
    guard let mctx = CGContext(
        data: base, width: W, height: H,
        bitsPerComponent: 8, bytesPerRow: maskBytesPerRow,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { return }
    mctx.translateBy(x: 0, y: CGFloat(H))
    mctx.scaleBy(x: 1, y: -1)
    mctx.setFillColor(gray: 0, alpha: 1)
    mctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    mctx.setFillColor(gray: 1, alpha: 1)
    mctx.setShouldAntialias(true)

    let size: CGFloat = 90
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: .semibold),
        .foregroundColor: NSColor.white,
    ]
    for (i, nits) in bands.enumerated() {
        let label = "\(Int(nits)) nit"
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attrs))
        let yCenter = CGFloat(i * bandH) + CGFloat(bandH) / 2 + size / 3
        mctx.saveGState()
        mctx.translateBy(x: 120, y: yCenter)
        mctx.scaleBy(x: 1, y: -1)
        mctx.textPosition = .zero
        CTLineDraw(line, mctx)
        mctx.restoreGState()
    }
}

// Composite mask onto PQ buffer with per-band contrast brightness.
// Bright bands (>= 600 nit) get dark labels; dim bands get bright labels.
for y in 0..<H {
    let bandIdx = min(y / bandH, bands.count - 1)
    let bandNits = bands[bandIdx]
    // Pick label brightness ~3 stops away from band brightness so labels stay
    // legible across the whole ladder. The 400 nit band is the worst case for
    // either choice, so we use it as the dividing line.
    let labelNits = bandNits >= 400 ? 2.0 : 1200.0
    let labelPQ = pqEncode(nits: labelNits)
    let labelVal = UInt16(min(max(labelPQ * 65535.0, 0), 65535).rounded())

    for x in 0..<W {
        let m = mask[y * maskBytesPerRow + x]
        if m == 0 { continue }
        let alpha = Double(m) / 255.0
        let off = y * rowBytes + x * bytesPerPixel
        let bgVal = UInt16(bytes[off]) | (UInt16(bytes[off + 1]) << 8)
        let blended = UInt16((1 - alpha) * Double(bgVal) + alpha * Double(labelVal))
        writePQ(off, blended)
    }
}

let data = Data(bytes)
guard let provider = CGDataProvider(data: data as CFData) else { exit(1) }
let bitmapInfo: CGBitmapInfo = [CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                 CGBitmapInfo.byteOrder16Little]
guard let image = CGImage(
    width: W, height: H,
    bitsPerComponent: 16, bitsPerPixel: 48,
    bytesPerRow: rowBytes,
    space: CGColorSpace(name: CGColorSpace.genericRGBLinear) ?? CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: bitmapInfo,
    provider: provider,
    decode: nil,
    shouldInterpolate: false,
    intent: .defaultIntent
) else { exit(1) }

let url = URL(fileURLWithPath: outputPath)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, image, [kCGImagePropertyHasAlpha: false] as CFDictionary)
CGImageDestinationFinalize(dest)
SWIFT

echo "Rendering HDR bands PNG..."
swift "$SWIFT_PATH" "$PNG_PATH"

echo "Encoding HDR10 HEVC..."
ffmpeg -y \
    -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
    -loop 1 -framerate 30 -i "$PNG_PATH" \
    -t 10 \
    -c:v libx265 -preset slow -crf 18 \
    -pix_fmt yuv420p10le \
    -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
    -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:hdr-opt=1:repeat-headers=1:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1600,1600" \
    -tag:v hvc1 \
    -movflags +faststart "$OUTPUT" \
    -hide_banner -loglevel warning

echo "Done: $OUTPUT"
