# Changelog

## [0.3.0] - 2026-10-03

Playlists, folder playback, volume controls, and fixes for DTS audio and slow
Matroska seeking. Changes since v0.2.7:

### Added

- **Playlists:** open multiple videos together, choose any entry, add more files,
  and remove entries without deleting the files. The playlist panel highlights
  and scrolls to the current video; playback controls show its position in the list.
- **Folder playback:** open a folder and include videos from its subfolders, in
  natural filename order (`clip2` before `clip10`). Scanning runs off the UI thread
  and excludes hidden files and app-package contents.
- **Shuffle:** play each entry in a shuffled order while keeping the visible list
  stable. Enabling shuffle keeps the current video; Previous retraces that order.
- **Loop modes:** Off, Current File, and Playlist. Playback advances automatically
  at file end; current-file looping reuses the existing playback pipeline. With
  looping off, the final video rewinds and pauses, ready to replay with Space.
- **Playlist persistence:** save M3U8 playlists and open M3U or M3U8 files, including
  relative paths and local `file:` URLs. Duplicate entries are removed.
- **Playlist controls:** Previous/Next buttons, a playlist panel, shuffle and loop
  controls, and a Playback menu. Files that fail to open are skipped when another
  entry is available; an unsuccessful pass stops instead of looping indefinitely.
- **Volume control:** Up/Down adjust volume by 10%, from mute to 100%, with a status
  overlay. Volume applies to both playback engines and carries over between files.
- Explicit Finder/open-panel file-type declarations for WebM and M3U/M3U8 playlists.

### Keyboard changes

- **Q / W:** previous / next file.
- **P:** show or hide the playlist.
- **Up / Down:** raise / lower volume; these keys previously sought by ten seconds.
- **Left / Right:** continue to seek backward / forward by ten seconds.
- **Command-O:** open videos, a folder, or a saved playlist.
- **Shift-Command-O:** open a folder.
- **Option-Command-O:** add files, folders, or saved playlists to the current playlist.

### Fixed

- **DTS dialogue popping and crackling:** decoded PCM now advances on an exact
  sample clock instead of reproducing the tiny gaps and overlaps between rounded
  Matroska timestamps. Real timestamp discontinuities remain intact, and timing
  resets on seeks and sample-rate changes.
- **Slow seeks in long MKV movies:** video seeks now use the video track's index
  entries. Subtitle entries were incorrectly treated as video keyframes, causing
  stalls even on ten-second skips. Later-film seeks in the Lighthouse test dropped
  from roughly 3.1 seconds to 0.16–0.25 seconds on the test machine.
- DTS prediction and synthesis history receive a short warm-up after seeking,
  even when the file does not declare audio pre-roll.
- Laced DTS frames receive codec-derived durations when the container does not
  supply frame durations. Post-seek audio priming uses a shorter buffer than startup.
- **Progress bar and timer jumping backward during seeks:** clicking or dragging
  immediately displays the requested time and keeps it there until playback
  catches up. Old clock updates and obsolete seek completions cannot overwrite it;
  native-engine completion waits for the asynchronous playback-clock time jump.
- **Scale selector appearance:** Off/Fit/Fill now explicitly shows the selected
  option in purple, independently of the system's default segmented-control tint.
- Late seek, end-of-file, and playback-error callbacks from a previous file no
  longer update the newly selected video during rapid playlist navigation.
- Cancelled MP4 setup cannot activate an obsolete playback engine after switching
  files; clearing the playlist tears down playback and releases the sleep assertion.

### Verification

- Added `playback_verify.sh` and regression coverage for mixed subtitle/video cue
  indexes, multiple tracks in one cue point, hour-long PCM timing at 48/44.1 kHz,
  discontinuities, resets, and sample-rate changes.
- Checked the Lighthouse file at 45, 60, 75, and 100 minutes, including ten-second
  seeks; all checked DTS PCM buffers remain contiguous.
- DTS reference-decoder conformance checks pass for all eight existing vectors.
- Playlist checks cover automatic advancement, both loop modes, shuffle, navigation,
  removal, recursive folder scanning, and M3U/M3U8 round trips.

Requires macOS 26 or later and Apple Silicon.

[0.3.0]: https://github.com/dh60/MetalFrame/compare/v0.2.7...v0.3.0
