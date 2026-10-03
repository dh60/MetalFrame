#!/usr/bin/env bash
# Demux/PCM timing regressions; optional argument tests a real DTS movie.
set -euo pipefail
cd "$(dirname "$0")"
WORK=$(mktemp -d /tmp/metalframe-playback.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
swiftc -O MKVDemuxer.swift AudioPipeline.swift DTSDecoder.swift dts_tables.swift \
    VideoDecodePipeline.swift HDRDynamicMetadata.swift tests/PlaybackRegression.swift \
    -module-cache-path "$WORK/module-cache" -o "$WORK/verify" \
    -framework AVFoundation -framework CoreMedia -framework VideoToolbox \
    -framework AudioToolbox -lcompression
"$WORK/verify" "$@"
