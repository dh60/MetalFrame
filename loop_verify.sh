#!/usr/bin/env bash
# macOS integration checks for real AVPlayer/native playback; requires ffmpeg.
set -euo pipefail
cd "$(dirname "$0")"
WORK=$(mktemp -d /tmp/metalframe-loops.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
ffmpeg -hide_banner -loglevel error \
    -f lavfi -i testsrc2=size=320x180:rate=30 \
    -f lavfi -i sine=frequency=440:sample_rate=48000 \
    -t 1 -c:v libx264 -pix_fmt yuv420p -g 30 -c:a aac "$WORK/loop.mp4"
ffmpeg -hide_banner -loglevel error -i "$WORK/loop.mp4" -c copy "$WORK/loop.mkv"
ffmpeg -hide_banner -loglevel error -i "$WORK/loop.mp4" \
    -c:v copy -c:a dca -strict -2 "$WORK/loop-dts.mkv"
# Compile the actual renderer, with the integration harness as the entry point.
python3 - "$WORK/renderer.swift" <<'PY'
import sys
from pathlib import Path
Path(sys.argv[1]).write_text(Path('metalframe.swift').read_text().replace(
    '@main\nstruct MetalFrame:', 'struct MetalFrame:', 1))
PY
swiftc -O "$WORK/renderer.swift" Playlist.swift MKVDemuxer.swift MP4Demuxer.swift \
    HDRDynamicMetadata.swift VideoDecodePipeline.swift AudioPipeline.swift \
    PlaybackEngine.swift DTSDecoder.swift dts_tables.swift tests/LoopRegression.swift \
    -module-cache-path "$WORK/module-cache" -o "$WORK/verify" \
    -framework SwiftUI -framework Metal -framework MetalKit -framework MetalFX \
    -framework AVFoundation -framework CoreVideo -framework VideoToolbox \
    -framework AudioToolbox -lcompression -parse-as-library
"$WORK/verify" "$WORK"
