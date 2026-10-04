#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Version stamped into Info.plist; CI can override it for release builds.
VERSION="${VERSION:-0.3.1}"

# Clean build
rm -rf MetalFrame.app

# Create the app bundle structure first
mkdir -p MetalFrame.app/Contents/MacOS

# Compile the Swift code + link (optimized — swiftc defaults to -Onone)
swiftc metalframe.swift \
    Playlist.swift \
    MKVDemuxer.swift \
    MP4Demuxer.swift \
    HDRDynamicMetadata.swift \
    VideoDecodePipeline.swift \
    AudioPipeline.swift \
    PlaybackEngine.swift \
    DTSDecoder.swift \
    dts_tables.swift \
    -O \
    -o MetalFrame.app/Contents/MacOS/MetalFrame \
    -framework SwiftUI -framework Metal -framework MetalKit \
    -framework MetalFX -framework AVFoundation -framework CoreVideo \
    -framework VideoToolbox -framework AudioToolbox -lcompression \
    -parse-as-library

# Create Info.plist
cat << EOF > MetalFrame.app/Contents/Info.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>MetalFrame</string>
    <key>CFBundleIdentifier</key>
    <string>com.dh60.MetalFrame</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.mpeg-4</string>
                <string>public.movie</string>
                <string>org.matroska.mkv</string>
                <string>org.matroska.webm</string>
                <string>com.dh60.metalframe.playlist</string>
            </array>
        </dict>
    </array>
    <!-- .mkv has no system-declared UTI; without this import it resolves to a
         dynamic UTI that doesn't conform to public.movie, so the open panel and
         Finder associations would reject it on machines where no other app
         declares Matroska. -->
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.dh60.metalframe.playlist</string>
            <key>UTTypeDescription</key>
            <string>M3U Playlist</string>
            <key>UTTypeConformsTo</key>
            <array><string>public.text</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>m3u</string><string>m3u8</string></array>
                <key>public.mime-type</key>
                <array><string>audio/x-mpegurl</string></array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>org.matroska.webm</string>
            <key>UTTypeDescription</key>
            <string>WebM Video</string>
            <key>UTTypeConformsTo</key>
            <array><string>public.movie</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>webm</string></array>
                <key>public.mime-type</key>
                <array><string>video/webm</string></array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>org.matroska.mkv</string>
            <key>UTTypeDescription</key>
            <string>Matroska Video</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.movie</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>mkv</string>
                </array>
                <key>public.mime-type</key>
                <array>
                    <string>video/x-matroska</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
EOF

codesign --force --sign - MetalFrame.app

echo "Build complete!"
