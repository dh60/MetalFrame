# MetalFrame Native Playback Engine — Implementation Plan

Handoff plan written 2026-07-16 after a long design session. The executing agent should
read this fully before touching code. Baseline commit: `8f8ce58` on `main`
(remote: https://github.com/dh60/MetalFrame.git, HTTPS auth works from this machine;
SSH does not).

## Context — why this exists

MetalFrame is a single-file reference-tier macOS video player (`metalframe.swift`,
~1,800 lines, built by `./build.sh` → one `swiftc -O` invocation, ad-hoc codesigned,
no Xcode project). Rendering is Metal 4 (MTL4CommandQueue/Buffer/Compiler/
ArgumentTable/ResidencySet), MTL4FXSpatialScaler upscaling, hand-written
ewa_lanczossharp downscaling, hand-written PQ/HLG/sRGB transfer functions, YUV intake
shader with Mitchell chroma upsampling and rotation/PAR support, EDR output on an
rgba16Float CAMetalLayer. All of that is DONE, verified, and must not regress.

The problem: playback is AVPlayer-based, and AVFoundation cannot demux Matroska.
Today `.mkv` files are handled by shelling out to Homebrew ffmpeg and remuxing to a
temp MP4 — which duplicates files that can be 80 GB (4K remuxes) and requires the
user to have installed ffmpeg. Both are unacceptable.

**Decisions already made with the user (do not relitigate):**

1. The app must be fully self-contained: user installs nothing, no Homebrew, no
   bundled third-party libraries, no ffmpeg (not even statically linked). Everything
   ships as Swift compiled by `build.sh`.
2. DTS, DTS-HD MA, TrueHD, and Dolby Atmos support are hard requirements. The goal
   is to fully replace mpv for the user's library (mostly MKV: x264/x265/AV1 video;
   EAC3/AC3/AAC/Opus/FLAC audio on web content; TrueHD/DTS-HD on Bluray remuxes).
3. Architecture: custom Swift Matroska demuxer + VideoToolbox video decode into the
   EXISTING Metal pipeline + AVSampleBufferAudioRenderer/AVSampleBufferRenderSynchronizer
   audio & clock, with hand-written Swift decoders only for what macOS can't decode
   (DTS family, TrueHD). MediaExtension and ffmpeg-linking approaches were considered
   and rejected (MediaExtension has no audio-decoder plugin point; ffmpeg violates
   self-containment).
4. Atmos reality (explained to and accepted by the user): E-AC-3 JOC Atmos gets true
   object rendering via Apple's licensed decoder + spatializer — better than mpv.
   TrueHD-Atmos gets the 7.1 lossless base presentation (objects are proprietary;
   mpv can't render them either) which Apple's spatializer will still virtualize.
5. Dolby Vision: Profile 8 plays as its HDR10 base layer through the existing PQ
   pipeline (day one, no work). Profile 5 RPU reshaping is a late phase.
6. MetalSlide (sibling repo) is out of scope entirely.

## Environment facts (verified this session — don't rediscover)

- macOS 26.5.2, Xcode 26.6, Apple M4 Pro (hardware AV1 decode present).
- Offline Metal toolchain NOT installed (`xcrun metal` fails). Runtime MTL4Compiler
  shader compilation works fine — the app compiles its shaders from source strings.
- Homebrew ffmpeg/ffprobe exist at /opt/homebrew/bin — usable as a DEV-ONLY oracle
  and test-asset generator. Never a runtime dependency of the shipped app.
- `MTLFXSpatialScalerDescriptor.supportsMetal4FX(_:)` is the correct Metal4FX gate
  (already used). MetalFX has no API newer than macOS 26.0.
- E2E verification pattern that works here (accessibility already granted to the
  terminal): build → `open -a MetalFrame.app file` → drive keys via
  `osascript`/System Events → capture ONLY the app window:
  `screencapture -x -l $(winid MetalFrame) out.png` — the `winid` helper is a
  10-line Swift CLI using `CGWindowListCopyWindowInfo` filtering `kCGWindowOwnerName`
  and layer 0 (rebuild it in the scratchpad; prior session's copy lives in a dead
  scratchpad). Watch `log stream --process MetalFrame --level error` for Metal/VT
  errors. ALWAYS window-only captures — never full-display (user preference, also in
  memory).
- Existing test assets in repo dir (untracked): `test_pattern_8k.mp4` (SDR 8K),
  `test_pattern_hdr.mp4` (HEVC PQ 4K nit-step pattern). Generate MKVs with the dev
  ffmpeg (`-f lavfi testsrc/testsrc2`, `-display_rotation`, audio encoders: ac3,
  eac3, aac, flac, libopus, dca (`-strict -2`), truehd (`-strict -2`) — ffmpeg HAS
  experimental DTS and TrueHD encoders, perfect for test files). The user also has
  real 4K DV/Atmos remuxes to supply on request.

## Current playback data flow (to be replaced)

`AVPlayer` + `AVPlayerItemVideoOutput` → per-vsync pull in `draw(in:)` keyed by
`itemTime(forHostTime: displayLink.targetTimestamp)` → CVPixelBuffer (biplanar
420v/420f/x420/xf20) → CVMetalTextureCache → y/cbcr MTLTextures → intake shader →
linear rgba16Float → EWA / MetalFX / blit → drawable, `present(at: targetTimestamp)`.
Colorspace comes from `CVBufferCopyAttachments` + `CVImageBufferCreateColorSpaceFromAttachments`
→ `classify()` sets layer colorspace/EDR/transfer function. Subtitles via
`AVPlayerItemLegibleOutput` → `subtitleText` overlay. FPS/drop counters measure
presented rate + PTS gaps. A `MTLSharedEvent` keeps one frame in flight.

The genius of the existing design for this migration: the render loop is ALREADY a
pull-by-timestamp consumer. The engine only has to replace the producer.

## Target architecture

```
                    ┌────────────────────────────────────────────┐
                    │ MKVDemuxer (pure Swift, from scratch)      │
                    │ EBML → Tracks/Clusters/Cues → packets      │
                    └───────┬───────────────────────┬────────────┘
                     video packets            audio packets        text packets
                            │                       │                   │
              ┌─────────────▼──────────┐   ┌────────▼─────────────┐  SRT/ASS parse
              │ VTDecompressionSession │   │ AudioRouter          │      │
              │ (hw H.264/HEVC/AV1)    │   │ passthrough: AC3/    │  subtitleText
              │ → reorder by PTS       │   │ EAC3(JOC)/AAC/FLAC/  │   overlay
              │ → FrameQueue (~6)      │   │ Opus/PCM             │  (existing UI)
              └─────────────┬──────────┘   │ Swift decoders:      │
                            │              │ DTS core/XLL, TrueHD │
             draw(in:) pulls newest        │ → PCM                │
             frame with pts <= now ─────── │ CMSampleBuffers →    │
                            │              │ AVSampleBufferAudio- │
                    existing Metal         │ Renderer             │
                    pipeline (UNCHANGED)   └────────┬─────────────┘
                            │                       │
                            └── clock: AVSampleBufferRenderSynchronizer timebase ──┘
```

- **Clock**: `AVSampleBufferRenderSynchronizer` owns rate and time; the audio
  renderer is attached so the audio device disciplines the clock. Video pull
  converts the display link's `targetTimestamp` (host time) to media time via
  `CMSyncConvertTime(hostTime, from: CMClockGetHostTimeClock(), to: synchronizer.timebase)`
  — direct analog of today's `itemTime(forHostTime:)`.
- **Play/pause** = `synchronizer.setRate(1/0, time:)`. **Seek** = pause → demuxer
  seeks via Cues to keyframe cluster ≤ target → VT flush + FrameQueue clear + audio
  renderer `flush()` → decode/enqueue from keyframe (decode-and-drop video frames
  with pts < target for frame-accurate seek) → `setRate(1, time: target)`. Keep the
  existing `isSeeking` freeze-frame UX and `pendingSeekTime` logic.
- **EOF**: demuxer exhausted + queues drained → existing rewind-to-zero-and-pause
  behavior (`AVPlayerItemDidPlayToEndTime` handler logic ports over).
- **MP4/MOV**: Phase 1 keeps the current AVPlayer path for non-MKV untouched
  (lowest risk). Phase 4 unifies: define a `Demuxer` protocol; the MP4 implementation
  wraps `AVAssetReader` (compressed sample output — no MP4 parsing needed), then
  delete AVPlayer entirely.

## Matroska demuxer — specifics

EBML: varint element IDs and sizes (lead-bit length coding; size all-ones =
unknown/streaming, treat as until-parent-end). Parse path: EBML Header (verify
DocType matroska/webm) → Segment → SeekHead (index to Info/Tracks/Cues; Cues may
also be discovered by SeekHead only — handle Cues at file end via SeekHead offset,
NOT by scanning) → Info (`TimestampScale`, default 1,000,000 ns; `Duration`) →
Tracks → stream Clusters lazily.

TrackEntry: TrackNumber, TrackUID, TrackType (1 video, 2 audio, 17 subtitle),
FlagDefault/FlagForced, Language/LanguageBCP47, Name, CodecID, CodecPrivate,
CodecDelay, SeekPreRoll, DefaultDuration; Video{PixelWidth/Height,
DisplayWidth/Height (→ PAR: displayAspect pipeline input), Colour{...}}; Audio
{SamplingFrequency, OutputSamplingFrequency, Channels, BitDepth}.

Block/SimpleBlock: track varint, int16 timestamp relative to Cluster Timestamp
(scale by TimestampScale), flags: SimpleBlock keyframe bit 0x80; lacing bits 0x06
(none/Xiph/fixed/EBML — audio commonly laced; implement all three, they're small).
BlockGroup wraps Block + BlockDuration (subtitles need it) + ReferenceBlock (absence
= keyframe for non-SimpleBlock). BlockAdditions carry DV RPUs (ignore until DV
phase, but don't choke on them).

Cues: CuePoint{CueTime, CueTrackPositions{CueTrack, CueClusterPosition (offset from
Segment data start), CueRelativePosition}}. If a file has no Cues (rare, unfinished
rips): fall back to linear cluster scan from start for seeks — correct, just slow;
do not build a full-file index eagerly.

CodecID → CMFormatDescription mapping (the load-bearing table):

| CodecID | Handling |
|---|---|
| V_MPEG4/ISO/AVC | CodecPrivate IS an `avcC` box payload → `CMVideoFormatDescriptionCreate` with `kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms` = {"avcC": data}. Samples are length-prefixed (NAL length size from avcC byte 4 & 3) — matches VT expectations as-is |
| V_MPEGH/ISO/HEVC | CodecPrivate = `hvcC` → extension atom "hvcC", codec 'hvc1' |
| V_AV1 | CodecPrivate = `av1C` → extension atom "av1C", codec 'av01'; samples are raw OBUs (temporal units) |
| A_AAC | CodecPrivate = AudioSpecificConfig → ASBD via `AudioFormatGetProperty(kAudioFormatProperty_FormatInfo)` with magic cookie (wrap ASC in esds cookie form CoreAudio accepts — test both raw ASC and esds) |
| A_AC3 / A_EAC3 | Self-framed syncframes; ASBD `kAudioFormatAC3` / `kAudioFormatEnhancedAC3`, no cookie. E-AC-3 JOC (Atmos) rides the same ID — the OS decoder handles it |
| A_FLAC | CodecPrivate = "fLaC" + metadata blocks → `kAudioFormatFLAC`, cookie = STREAMINFO (verify exact cookie shape CoreAudio wants) |
| A_OPUS | CodecPrivate = OpusHead → `kAudioFormatOpus`; honor CodecDelay (pre-skip) and SeekPreRoll (80 ms re-decode after seeks) |
| A_DTS | Phase 2 (own decoder). Syncword 0x7FFE8001; DTS-HD substreams 0x64582025 |
| A_TRUEHD / A_MLP | Phase 3 (own decoder). TrueHD major sync 0xF8726FBA / MLP 0xF8726FBB |
| S_TEXT/UTF8 | SRT: block payload is plain UTF-8 cue text, timing = block ts + BlockDuration |
| S_TEXT/ASS | Dialogue line — split on commas (9 header fields, text is 10th), strip `{\...}` override tags, honor `\N` |
| S_HDMV/PGS | Phase 5 |

Colour element → format-description extensions so the EXISTING colorspace logic
keeps working unchanged: map MatrixCoefficients/Primaries/TransferCharacteristics
(1=709, 9=2020, 16=PQ, 18=HLG) to `kCMFormatDescriptionExtension_YCbCrMatrix` /
`ColorPrimaries` / `TransferFunction` CFString constants; Range → pixel format
choice validation; MasteringMetadata/MaxCLL → mastering-display/content-light
extensions. VT propagates these onto output CVPixelBuffers, which
`CVBufferCopyAttachments` + `classify()` already consume. If a track lacks Colour
metadata, fall back to h264/hevc VUI (VT derives attachments from SPS in the
parameter sets — verify with an untagged file; the app already handles the
"Colorspace: Unknown" fallback gracefully).

## Video path — specifics

`VTDecompressionSessionCreate` with `destinationImageBufferAttributes`: pixel format
array (420v/420f 8-bit, x420/xf20 10-bit), IOSurface + Metal compatibility (mirror
the dictionary currently passed to AVPlayerItemVideoOutput). Decode on a dedicated
thread; `kVTDecodeFrame_EnableAsynchronousDecompression`; output callback receives
(imageBuffer, pts, duration) in DECODE order → reorder: min-heap by PTS, release
frames once heap depth > reorder window (use max_num_reorder_frames if parsed, else
depth 6). FrameQueue: ring buffer ~6 display-ordered frames; decode thread blocks
(condition) when full — that's the backpressure. `draw(in:)` takes the newest frame
with pts ≤ current media time, keeps last frame during seeks (existing behavior),
feeds the exact same CVMetalTextureCache path (`ySource`/`cbcrSource` retention
pattern stays). FPS/drop counters: port as-is — drop detection compares consecutive
*taken* frame PTS gaps vs track frame duration.

Handle `VTDecompressionSessionCanAcceptFormatDescription` false mid-stream (SPS
change) → new session. `kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder`
true (require hw; fall back to allowing sw for h264/hevc, AV1 has no sw decoder).
On decode error frames: skip, count as dropped, log — never stall the queue.

## Audio path — specifics

One `AVSampleBufferAudioRenderer` on the synchronizer. Feed via
`requestMediaDataWhenReady(on:)`: pull packets from the selected audio track,
package as CMSampleBuffers:
- Passthrough codecs: `CMAudioSampleBufferCreateReadyWithPacketDescriptions`, one or
  more packets per buffer, PTS from block timestamps. Set
  `renderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel`
  (enables JOC Atmos object rendering + multichannel spatialization).
- Swift-decoded codecs (DTS/TrueHD): decoder emits interleaved PCM (Float32 or
  Int32 for lossless bit-exactness — Float32 fine for output); package as PCM
  CMSampleBuffers with `CMAudioFormatDescription` matching the decoded layout
  (5.1/7.1 channel layouts: use `kAudioChannelLayoutTag_MPEG_5_1_A` / `_7_1_A` —
  verify against Dolby/DTS channel orders and permute; DTS channel order differs
  from CoreAudio order — this WILL bite, write a layout-permutation table early).
- Track selection: default = first audio track preferring FlagDefault, but if the
  default is a codec we can't decode yet (phase-dependent), auto-fall-forward to the
  first decodable track and surface it in `statusLabel`. Add `a` key to cycle audio
  tracks (mirror the `s` subtitle pattern; flush renderer + re-enqueue on switch).
- Files with NO decodable audio track (e.g. DTS-only before phase 2): play video
  silently with a status overlay saying which phase is missing — never refuse the file.
- A/V start alignment: don't set rate until both first video frame is queued and
  renderer has ≥ ~200 ms buffered; prime then `setRate(1, time: startTime)`.

## Own decoders (the summit)

**Phase 2 — DTS core** (public spec: ETSI TS 102 114). Frame: sync 0x7FFE8001 (
14-bit legacy variant 0x1FFFE800 exists — detect and support), header (sample rate,
channel arrangement, LFE), subband analysis: 32-band QMF, ADPCM prediction, Huffman/
VQ coded subband samples, scale factors. Implement filterbank with vDSP. Deliverables
include a conformance harness: decode test vectors, compare vs dev-ffmpeg PCM output
(`ffmpeg -i x.dts -f f32le -`) — lossy codec so compare with SNR threshold (> ~90 dB
against reference implementation indicates table/filterbank correctness), not
bit-equality.

**Phase 3 — TrueHD/MLP**. No public spec; clean Swift implementation guided by
public reverse-engineered knowledge (ffmpeg's mlpdec, the MLP patent US 6,664,913,
and format writeups). Structure: access units of substream segments (up to 4
substreams: 2ch downmix, 6ch, 8ch presentations — decode the highest present),
restart headers, matrix primitives, FIR/IIR channel prediction filters, Huffman
entropy coding, sample rate up to 192 kHz. CRITICAL self-verification: MLP embeds
parity/CRC check nibbles per access unit and lossless-check bytes — a correct
decoder can PROVE bit-exactness from the stream itself. Also compare vs dev-ffmpeg
(`-c:a truehd` encodes + decodes for round-trip vectors). Atmos: presentation 16-ch
substream/metadata is ignored; decode 7.1 base.

**Phase 4 — DTS-HD MA (XLL)**. Extension substream (sync 0x64582025) → asset
descriptors → XLL lossless: entropy-coded residuals + fixed prediction over the
core (hybrid: core decode from phase 2 + lossless residual reconstruction = bit-
exact PCM; pure-XLL files exist too). Verify bit-exactness vs dev-ffmpeg decode of
DTS-HD MA samples. Also handle DTS-HD HRA (lossy extension) by decoding core only
(acceptable; note in status label).

LGPL hygiene note for the executing agent: do NOT translate ffmpeg source
line-by-line into Swift. Use it as a behavioral oracle and for understanding; write
original code. (The user's repos are public; the concern is provenance cleanliness,
which also matters to them — "everything from scratch" is the brief.)

## Phase plan with acceptance criteria

Each phase: `./build.sh` clean (zero warnings), E2E-verified per the method above,
committed on `main` with a clean message (NO Co-Authored-By / AI attribution —
user's global CLAUDE.md rule). Push only when the user asks.

**Phase 1 — Engine core + MKV + Apple-codec audio.**
New files: `MKVDemuxer.swift`, `VideoDecodePipeline.swift`, `AudioPipeline.swift`,
`PlaybackEngine.swift` (or similar); `build.sh` compiles the file list (still one
swiftc call, `-parse-as-library -O`). Renderer gains an engine-vs-AVPlayer switch on
container type; ALL remux code deleted (`remuxIfNeeded`, ffmpeg discovery,
`RemuxingIndicator`, `isRemuxing`, `cleanupRemux`).
Accept: h264+eac3, hevc(10-bit PQ)+ac3, av1+opus MKVs play with correct color
(HDR pattern MKV shows PQ EDR exactly like the MP4 version), audio in sync (verify
with a generated AV-sync beep/flash test clip — ffmpeg `testsrc2` + `sine` with
beep-on-flash filter), seek works both directions mid-file and near EOF, subtitles
(SRT + ASS tracks) render, 'a' cycles audio tracks, FPS/drop counters live, EOF
rewinds+pauses, an 80GB-class file opens in < 2 s (generate a large sparse test or
verify open time is independent of file size — read only header + first cluster +
Cues), MP4 path regression-tested (8K + HDR patterns), zero Metal/VT errors in logs.

**Phase 2 — DTS core decoder.** `DTSDecoder.swift` + `dts_tables.swift`.
Accept: generated dca MKV plays; SNR harness passes vs dev-ffmpeg reference; 5.1
layout order verified by channel-ID test tone file (front-left beep goes left...).

**Phase 3 — TrueHD decoder.** `TrueHDDecoder.swift`.
Accept: MLP internal CRC/lossless-check passes across a full file; bit-exact vs
round-trip vectors; real Bluray remux sample from user plays lossless 7.1; Apple
spatializer engages (verify via `statusLabel`/renderer property introspection).

**Phase 4 — DTS-HD MA + unification.** XLL bit-exact; MP4 moves onto the engine via
AVAssetReader-backed demuxer implementation; AVPlayer deleted; single pipeline.

**Phase 5 — polish to mpv-parity+.** PGS subtitle decode (RLE bitmap → texture
composited in the final pass), MKV chapters (menu + keybinds), DV Profile 5 RPU
reshaping in the Metal pipeline (reference: dovi_tool/libplacebo knowledge; P8
already correct as HDR10), attachments (fonts — only matters if ASS styling ever
goes beyond stripped text).

## Risks / verify-early list

1. CMFormatDescription extension-atom shapes for avcC/hvcC/av1C from CodecPrivate —
   build a 20-line spike that plays one h264 MKV video-only before writing the full
   demuxer surface. If VT rejects, compare against an MP4's format description of
   the same stream (`CMVideoFormatDescriptionGetExtensions` dump).
2. AVSampleBufferAudioRenderer accepting raw AC3/EAC3/FLAC/Opus packet streams and
   JOC spatialization actually engaging — spike with a generated file per codec.
   (AC3/EAC3 near-certain; FLAC/Opus cookie shapes are the fiddly ones — worst case
   decode FLAC/Opus via AudioConverter manually, still zero third-party code.)
3. Opus pre-skip/edge trimming and seek pre-roll audio correctness.
4. DTS↔CoreAudio channel-order permutations.
5. VT color attachment propagation for streams without container Colour metadata.
6. 24.000 vs 23.976 and audio-clock drift: synchronizer should handle it (audio
   masters the clock) — verify long-play sync with the beep/flash clip at 30+ min
   (generate, don't sit through it: capture drift by comparing audio render time vs
   video PTS at intervals).

## Explicitly out of scope

MetalSlide. Networking/streaming. Atmos *object* rendering from TrueHD (impossible
without Dolby licensing — 7.1 base + Apple spatialization is the ceiling, same as
mpv). Encoding/transcoding of any kind. Windows/iOS.
