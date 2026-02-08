# MetalFrame
A video player for macOS using Metal 4 and MetalFX for high quality playback. Only supports HDR video at the moment.
![MetalFrame User Interface](screenshot.png)
## Features
- Plays HDR MPEG-4 videos (.mp4, .m4v)
- Metal 4 pipeline with reference rendering (no OS scaling, no tonemapping)
- MetalFX upscaling
## Keybinds
| Key | Action |
|-----|--------|
| Space | Play / Pause |
| Right / Down | Forward 10s |
| Left / Up | Back 10s |
| f | Toggle Fullscreen |
| i | Toggle info overlay |
| Esc | Quit |
## Info Overlay
Press `i` to show the info overlay, which displays video details and provides toggles for:
- **Scaling** - Enable/disable scaling
## Requirements
- macOS 26+
- Apple Silicon
