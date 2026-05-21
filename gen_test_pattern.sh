#!/usr/bin/env bash
# Generates an 8K (7680×4320) downscale-filter test pattern video.
# Five clean horizontal bands (top to bottom):
#   1. Title bar
#   2. Siemens star (centered) — tests every angle and frequency
#   3. Frequency-burst row — vertical stripes | horizontal stripes (1–8 px)
#   4. Checkerboard row (1, 2, 3, 4, 6, 8, 12, 16 px cells)
#   5. Text ladder (96 pt down to 8 pt)

set -euo pipefail

OUTPUT="${1:-test_pattern_8k.mp4}"

if ! command -v ffmpeg &>/dev/null; then
    echo "ffmpeg required: brew install ffmpeg" >&2
    exit 1
fi

TMP_DIR=$(mktemp -d -t mfpattern)
trap 'rm -rf "$TMP_DIR"' EXIT
PNG_PATH="$TMP_DIR/pattern.png"
SWIFT_PATH="$TMP_DIR/gen.swift"

cat > "$SWIFT_PATH" << 'SWIFT'
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import AppKit

let outputPath = CommandLine.arguments[1]
let W = 7680
let H = 4320

guard let ctx = CGContext(
    data: nil, width: W, height: H,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

// Flip the context so y=0 is at the top and grows downward — easier layout.
ctx.translateBy(x: 0, y: CGFloat(H))
ctx.scaleBy(x: 1, y: -1)

ctx.setShouldAntialias(false)
ctx.interpolationQuality = .none

ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)

func drawText(_ str: String, at p: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular) {
    ctx.saveGState()
    ctx.setShouldAntialias(true)
    ctx.translateBy(x: p.x, y: p.y)
    ctx.scaleBy(x: 1, y: -1) // un-flip for upright glyphs
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor.black,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: str, attributes: attrs))
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func textWidth(_ str: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight)]
    return NSAttributedString(string: str, attributes: attrs).size().width
}

// 1. Title
do {
    let s = "MetalFrame downscale test pattern — 8K (7680×4320)"
    let size: CGFloat = 72
    let w = textWidth(s, size: size, weight: .bold)
    drawText(s, at: CGPoint(x: (CGFloat(W) - w) / 2, y: 100), size: size, weight: .bold)
}

// 2. Siemens star — band y 200–1820
do {
    let bandTop: CGFloat = 200
    let bandH: CGFloat = 1620
    let cx = CGFloat(W) / 2
    let cy = bandTop + bandH / 2
    let r: CGFloat = (bandH - 160) / 2  // leave 80 px for label below
    let sectors = 144 // 72 black wedges
    for i in stride(from: 0, to: sectors, by: 2) {
        let a0 = CGFloat(i) / CGFloat(sectors) * 2 * .pi
        let a1 = CGFloat(i + 1) / CGFloat(sectors) * 2 * .pi
        let path = CGMutablePath()
        path.move(to: CGPoint(x: cx, y: cy))
        path.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: a0, endAngle: a1, clockwise: false)
        path.closeSubpath()
        ctx.addPath(path)
        ctx.fillPath()
    }
    let label = "Siemens star · \(sectors / 2) wedges"
    let size: CGFloat = 36
    let w = textWidth(label, size: size, weight: .medium)
    drawText(label, at: CGPoint(x: cx - w / 2, y: cy + r + 50), size: size, weight: .medium)
}

// 3. Frequency-burst row — band y 1900–2780 (880 tall)
//    Vertical bursts in left half, horizontal in right half.
let burstTop: CGFloat = 1900
let burstH: CGFloat = 880

// 3a. Vertical bursts (left half: x 200 – 3640)
do {
    let count = 8
    let groupGap: CGFloat = 60
    let usableW: CGFloat = 3440
    let groupW = (usableW - CGFloat(count - 1) * groupGap) / CGFloat(count)
    let stripeArea: CGFloat = burstH - 120
    for w in 1...count {
        let x0 = 200 + CGFloat(w - 1) * (groupW + groupGap)
        let stripeW = CGFloat(w)
        // Center stripes inside the group, leave a 20 px margin
        var sx = x0 + 10
        while sx + stripeW <= x0 + groupW - 10 {
            ctx.fill(CGRect(x: sx, y: burstTop + 60, width: stripeW, height: stripeArea))
            sx += stripeW * 2
        }
        drawText("\(w)px V", at: CGPoint(x: x0, y: burstTop + 50), size: 26, weight: .medium)
    }
}

// 3b. Horizontal bursts (right half: x 4040 – 7480)
do {
    let count = 8
    let groupGap: CGFloat = 28
    let leftMargin: CGFloat = 4040
    let rightMargin: CGFloat = 7480
    let usableH = burstH - 100
    let groupH = (usableH - CGFloat(count - 1) * groupGap) / CGFloat(count)
    let stripeArea: CGFloat = rightMargin - leftMargin - 240 // leave room for label on the right
    for w in 1...count {
        let y0 = burstTop + 80 + CGFloat(w - 1) * (groupH + groupGap)
        let stripeH = CGFloat(w)
        var sy = y0 + 5
        while sy + stripeH <= y0 + groupH - 5 {
            ctx.fill(CGRect(x: leftMargin, y: sy, width: stripeArea, height: stripeH))
            sy += stripeH * 2
        }
        drawText("\(w)px H", at: CGPoint(x: leftMargin + stripeArea + 30, y: y0 + groupH * 0.7), size: 26, weight: .medium)
    }
}

// 4. Checkerboard row — band y 2860–3460
do {
    let bandTop: CGFloat = 2860
    let cellSizes = [1, 2, 3, 4, 6, 8, 12, 16]
    let boardSize: CGFloat = 460
    let gap: CGFloat = 60
    let total: CGFloat = CGFloat(cellSizes.count) * boardSize + CGFloat(cellSizes.count - 1) * gap
    let xStart = (CGFloat(W) - total) / 2
    for (idx, s) in cellSizes.enumerated() {
        let bx = xStart + CGFloat(idx) * (boardSize + gap)
        let by = bandTop + 50
        let n = Int(boardSize) / s
        for ry in 0..<n {
            for rx in 0..<n {
                if (rx + ry) % 2 == 0 {
                    ctx.fill(CGRect(x: bx + CGFloat(rx * s), y: by + CGFloat(ry * s), width: CGFloat(s), height: CGFloat(s)))
                }
            }
        }
        drawText("\(s)px", at: CGPoint(x: bx, y: by - 12), size: 28, weight: .medium)
    }
}

// 5. Text ladder — band y 3540–4280
do {
    let sizes: [CGFloat] = [96, 64, 48, 36, 28, 22, 18, 14, 12, 10, 8]
    var y: CGFloat = 3580
    for size in sizes {
        let str = "\(Int(size))pt · The quick brown fox jumps over the lazy dog 0123456789"
        drawText(str, at: CGPoint(x: 200, y: y + size), size: size)
        y += size * 1.25
        if y > 4280 { break }
    }
}

guard let cgImage = ctx.makeImage() else { exit(1) }
let url = URL(fileURLWithPath: outputPath)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, cgImage, nil)
CGImageDestinationFinalize(dest)
SWIFT

echo "Rendering test pattern PNG..."
swift "$SWIFT_PATH" "$PNG_PATH"

echo "Encoding 10s static MP4..."
ffmpeg -y -loop 1 -framerate 30 -i "$PNG_PATH" \
    -t 10 -c:v libx264 -preset slow -crf 17 -pix_fmt yuv420p \
    -movflags +faststart "$OUTPUT" \
    -hide_banner -loglevel warning

echo "Done: $OUTPUT"
