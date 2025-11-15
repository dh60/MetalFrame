# Clean build
rm -rf MetalFrame.app

# Create the app bundle structure first
mkdir -p MetalFrame.app/Contents/MacOS

# Compile the Swift code
swiftc metalframe.swift -o MetalFrame.app/Contents/MacOS/MetalFrame -framework SwiftUI -framework Metal -framework MetalKit -framework MetalFX -framework AVFoundation -framework CoreVideo -parse-as-library

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
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
</dict>
</plist>
EOF

codesign --force --deep --sign - MetalFrame.app

echo "Build complete!"
