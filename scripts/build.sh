#!/bin/bash
# Build Claude Island for release
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/ClaudeIsland.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"

echo "=== Building Claude Island ==="
echo ""

# Clean previous builds
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

cd "$PROJECT_DIR"

# Build and archive
echo "Archiving..."
xcodebuild archive \
    -scheme ClaudeIsland \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_STYLE=Automatic \
    2>&1 | xcpretty || {
    echo "ERROR: Archive failed. Re-running with full output..."
    xcodebuild archive \
        -scheme ClaudeIsland \
        -configuration Release \
        -archivePath "$ARCHIVE_PATH" \
        -destination "generic/platform=macOS" \
        ENABLE_HARDENED_RUNTIME=YES \
        CODE_SIGN_STYLE=Automatic
    exit 1
}

# Create ExportOptions.plist if it doesn't exist
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

# Export the archive
echo ""
echo "Exporting..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    2>&1 | xcpretty || {
    echo "ERROR: Export failed. Re-running with full output..."
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS"
    exit 1
}

echo ""
echo "=== Build Complete ==="
echo "App exported to: $EXPORT_PATH/Claude Island.app"
echo ""
echo "Next: Run ./scripts/create-release.sh to notarize and create DMG"
