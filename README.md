# MetalFrame
A video player for macOS using Metal 4 and MetalFX for reference playback.
![MetalFrame User Interface](screenshot.png)
## Features
- Plays MPEG-4 videos (.mp4, .m4v) and MKV (remuxed via ffmpeg)
- HDR (PQ / HLG) with EDR, SDR in BT.709/BT.2020/P3 — reference color pipeline
- Rotated (portrait) and anamorphic sources displayed correctly
- Metal 4 pipeline with reference rendering (no OS scaling, no tone mapping)
- MetalFX upscaling; ewa_lanczossharp for downscaling
- Text subtitles
## Keybinds
| Key | Action |
|-----|--------|
| Space | Play / Pause |
| Right / Down | Forward 10s |
| Left / Up | Back 10s |
| f | Toggle Fullscreen |
| s | Cycle subtitle tracks |
| i | Toggle info overlay |
| Esc | Quit |
## Info Overlay
Press `i` to show the info overlay, which displays video details and provides:
- **Scale** - Off / Fit / Fill
## Requirements
- macOS 26+
- Apple Silicon
