#!/usr/bin/env bash
# DTS decoder conformance harness (dev-only; needs Homebrew ffmpeg as the
# reference oracle — never a runtime dependency of the app).
#
# Generates DTS core test vectors with ffmpeg's dca encoder, decodes them with
# our DTSDecoder, and compares f32 PCM against ffmpeg's decode. Passes when
# every channel of every vector exceeds 90 dB SNR (typical results: >100 dB).
set -euo pipefail
cd "$(dirname "$0")"
FF=${FF:-/opt/homebrew/bin/ffmpeg}
[ -x "$FF" ] || { echo "dev ffmpeg not found at $FF"; exit 1; }

WORK=$(mktemp -d /tmp/dtsverify.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Build the decoder CLI (main.swift naming is required for top-level code).
cat > "$WORK/main.swift" <<'EOF'
import Foundation
let args = CommandLine.arguments
guard args.count == 3, let data = FileManager.default.contents(atPath: args[1]) else { exit(2) }
let frames = DTSDecoder().decode(packet: data)
guard !frames.isEmpty else { FileHandle.standardError.write("no frames\n".data(using: .utf8)!); exit(1) }
var out = Data()
for f in frames { f.pcm.withUnsafeBufferPointer { out.append(Data(bytes: $0.baseAddress!, count: $0.count * 4)) } }
try! out.write(to: URL(fileURLWithPath: args[2]))
FileHandle.standardError.write("rate=\(frames[0].sampleRate) ch=\(frames[0].channelCount) frames=\(frames.count)\n".data(using: .utf8)!)
EOF
swiftc -O DTSDecoder.swift dts_tables.swift "$WORK/main.swift" -o "$WORK/dtsdec"

# Program material: per-channel pink noise + distinct tone so channel-mapping
# errors collapse the SNR instead of nearly passing.
make_src() { # channels rate
    local ch=$1 rate=$2 filter="" i
    for ((i=0; i<ch; i++)); do
        filter+="anoisesrc=r=${rate}:color=pink:seed=$((42+i)):a=0.25,lowpass=f=$((3000+2000*i))[n$i];"
        filter+="sine=r=${rate}:frequency=$((220*(i+1)))[s$i];"
        filter+="[n$i][s$i]amix=inputs=2:weights=1 0.4[c$i];"
    done
    for ((i=0; i<ch; i++)); do filter+="[c$i]"; done
    filter+="amerge=inputs=${ch}[out]"
    "$FF" -y -v error -filter_complex "$filter" -map '[out]' -t 6 \
        -c:a pcm_f32le "$WORK/src_${ch}_${rate}.wav"
}
make_src 1 48000; make_src 2 48000; make_src 6 48000; make_src 6 44100

encode() { # name src bitrate extra...
    local name=$1 src=$2 br=$3; shift 3
    "$FF" -y -v error -i "$WORK/$src" -c:a dca -strict -2 "$@" -b:a "$br" "$WORK/$name.dts"
    "$FF" -y -v error -i "$WORK/$name.dts" -f f32le "$WORK/$name.ref"
}
encode mono48       src_1_48000.wav 192k
encode stereo48hi   src_2_48000.wav 1536k
encode stereo48lo   src_2_48000.wav 320k
encode stereo48ad   src_2_48000.wav 448k -dca_adpcm 1
encode s5148hi      src_6_48000.wav 1536k
encode s5148lo      src_6_48000.wav 768k
encode s5148ad      src_6_48000.wav 768k -dca_adpcm 1
encode s5144        src_6_44100.wav 754500

fail=0
for v in mono48:1 stereo48hi:2 stereo48lo:2 stereo48ad:2 s5148hi:6 s5148lo:6 s5148ad:6 s5144:6; do
    name=${v%:*}; ch=${v#*:}
    "$WORK/dtsdec" "$WORK/$name.dts" "$WORK/$name.out" 2>/dev/null
    python3 - "$WORK/$name.ref" "$WORK/$name.out" "$ch" "$name" <<'PYEOF' || fail=1
import math, struct, sys
ref = open(sys.argv[1], "rb").read(); test = open(sys.argv[2], "rb").read()
ch = int(sys.argv[3]); name = sys.argv[4]
n = min(len(ref), len(test)) // 4
r = struct.unpack(f"<{n}f", ref[:n*4]); t = struct.unpack(f"<{n}f", test[:n*4])
worst = 1e99
for c in range(ch):
    sr = se = 0.0
    for i in range(c, (n // ch) * ch, ch):
        d = r[i] - t[i]; se += d * d; sr += r[i] * r[i]
    snr = 300.0 if se == 0 else (10 * math.log10(sr / se) if sr > 0 else 300.0)
    worst = min(worst, snr)
status = "PASS" if worst > 90 else "FAIL"
print(f"{name}: worst-channel SNR {worst:.1f} dB  {status}")
sys.exit(0 if worst > 90 else 1)
PYEOF
done
[ "$fail" = 0 ] && echo "ALL VECTORS PASS" || { echo "HARNESS FAILED"; exit 1; }
