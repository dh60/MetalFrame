# MetalFrame
A video player for macOS using Metal 4 and MetalFX for reference playback.
[Release changelog](CHANGELOG.md)
![MetalFrame User Interface](screenshot.png)
## Features
- Native Matroska playback: built-in MKV demuxer (pure Swift, no ffmpeg) feeding
  VideoToolbox — H.264, HEVC, AV1 with hardware decode
- Audio through the OS decoders: AC-3, E-AC-3 (incl. Atmos/JOC), AAC, FLAC, Opus;
  plus a from-scratch DTS core decoder (ETSI TS 102 114) — DTS and the core of
  DTS-HD play natively; `a` cycles between audio tracks (TrueHD and DTS-HD MA
  lossless are on the roadmap)
- Plays MPEG-4 videos (.mp4, .m4v) via AVFoundation
- HDR (PQ / HLG) with EDR, SDR in BT.709/BT.2020/P3 — reference color pipeline
- Rotated (portrait) and anamorphic sources displayed correctly
- Metal 4 pipeline with reference rendering (no OS scaling, no tone mapping)
- MetalFX upscaling; ewa_lanczossharp for downscaling
- Text subtitles (SRT and ASS tracks in MKV)
- Playlists: open multiple videos, add or remove files, and save/load M3U or M3U8
- Open a folder to play all its videos, including subfolders, in natural filename order
- Shuffle and loop the current file or the whole playlist; automatically advance at file end
## Keybinds
| Key | Action |
|-----|--------|
| Space | Play / Pause |
| q | Previous file |
| w | Next file |
| p | Show / hide playlist |
| Right | Forward 10s |
| Left | Back 10s |
| Up | Volume +10% (maximum 100%) |
| Down | Volume −10% (minimum 0%, muted) |
| f | Toggle Fullscreen |
| s | Cycle subtitle tracks |
| a | Cycle audio tracks |
| t | Toggle HDR tone mapping (BT.2390 vs clip to panel) |
| i | Toggle info overlay |
| ⌘O | Open files, a folder, or a saved playlist |
| ⇧⌘O | Open folder |
| ⌥⌘O | Add files / folders / saved playlists to the playlist |
| Esc | Quit |
## Playlists
Move the pointer to reveal playback controls. Use **Loop** to choose Off,
Current File, or Playlist, and the shuffle button to randomize playback order.
The same controls are available in the **Playback** menu. **Q** and **W** follow
the playback order, including while shuffled; current-file looping applies to
automatic playback, so these keys can still change files.

Press **P** to browse the playlist, select a video, remove entries, or add more.
**File → Save Playlist…** saves an M3U8 playlist; open it with **⌘O** to restore
the file list. With looping off, playback stops after the final video and rewinds
it for Space to replay. Files that fail to open are skipped when another video
is available. Codec support still determines which video formats can play.
Volume starts at 100% and carries over between files; Up/Down show the current
percentage in the status overlay.
## Info Overlay
Press `i` to show the info overlay, which displays video details and provides:
- **Scale** - Off / Fit / Fill
## Requirements
- macOS 26+
- Apple Silicon

## Playback checks
`./playback_verify.sh` checks video cue selection in mixed-track Matroska
indexes and an hour of continuous DTS PCM timing at 48 and 44.1 kHz. Pass a
movie path to also check its seek landings and decoded PCM buffer timing at
45, 60, 75, and 100 minutes, including ten-second forward seeks.
`./dts_verify.sh` compares the DTS decoder against FFmpeg (development only).
