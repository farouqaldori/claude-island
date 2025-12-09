#!/bin/bash
# Create a release: notarize, create DMG, sign for Sparkle, upload to GitHub, update website
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
EXPORT_PATH="$BUILD_DIR/export"
RELEASE_DIR="$PROJECT_DIR/releases"
KEYS_DIR="$PROJECT_DIR/.sparkle-keys"

# GitHub repository (owner/repo format)
GITHUB_REPO="farouqaldori/claude-island"

# Website repo for auto-updating appcast
WEBSITE_DIR="${CLAUDE_ISLAND_WEBSITE:-$PROJECT_DIR/../ClaudeIsland-website}"
WEBSITE_PUBLIC="$WEBSITE_DIR/public"

APP_PATH="$EXPORT_PATH/ClaudeIsland.app"
APP_NAME="ClaudeIsland"
KEYCHAIN_PROFILE="ClaudeIsland"

echo "=== Creating Release ==="
echo ""

# Check if app exists
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: App not found at $APP_PATH"
    echo "Run ./scripts/build.sh first"
    exit 1
fi

# Get version from app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")

echo "Version: $VERSION (build $BUILD)"
echo ""

mkdir -p "$RELEASE_DIR"

# ============================================
# Step 1: Notarize the app
# ============================================
echo "=== Step 1: Notarizing ==="

# Check if keychain profile exists
if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" &>/dev/null; then
    echo ""
    echo "No keychain profile found. Set up credentials with:"
    echo ""
    echo "  xcrun notarytool store-credentials \"$KEYCHAIN_PROFILE\" \\"
    echo "      --apple-id \"your@email.com\" \\"
    echo "      --team-id \"2DKS5U9LV4\" \\"
    echo "      --password \"xxxx-xxxx-xxxx-xxxx\""
    echo ""
    echo "Create an app-specific password at: https://appleid.apple.com"
    echo ""
    read -p "Skip notarization for now? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
    SKIP_NOTARIZATION=true
    echo "WARNING: Skipping notarization. Users will see Gatekeeper warnings!"
else
    # Create zip for notarization
    ZIP_PATH="$BUILD_DIR/$APP_NAME-$VERSION.zip"
    echo "Creating zip for notarization..."
    ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

    echo "Submitting for notarization..."
    xcrun notarytool submit "$ZIP_PATH" \
        --keychain-profile "$KEYCHAIN_PROFILE" \
        --wait

    echo "Stapling notarization ticket..."
    xcrun stapler staple "$APP_PATH"

    rm "$ZIP_PATH"
    echo "Notarization complete!"
fi

echo ""

# ============================================
# Step 2: Create DMG
# ============================================
echo "=== Step 2: Creating DMG ==="

DMG_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"

# Check if create-dmg is available (prettier DMG)
if command -v create-dmg &> /dev/null; then
    echo "Using create-dmg for prettier output..."
    create-dmg \
        --volname "Claude Island" \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "ClaudeIsland.app" 150 200 \
        --app-drop-link 450 200 \
        --hide-extension "ClaudeIsland.app" \
        "$DMG_PATH" \
        "$APP_PATH" || true

    # create-dmg returns error if DMG already exists, check if it worked
    if [ ! -f "$DMG_PATH" ]; then
        rm -f "$DMG_PATH"
        create-dmg \
            --volname "Claude Island" \
            --window-size 600 400 \
            --icon-size 100 \
            --icon "ClaudeIsland.app" 150 200 \
            --app-drop-link 450 200 \
            --hide-extension "ClaudeIsland.app" \
            "$DMG_PATH" \
            "$APP_PATH"
    fi
else
    echo "Using hdiutil (install create-dmg for prettier DMG: brew install create-dmg)"
    hdiutil create -volname "Claude Island" \
        -srcfolder "$APP_PATH" \
        -ov -format UDZO \
        "$DMG_PATH"
fi

echo "DMG created: $DMG_PATH"
echo ""

# ============================================
# Step 3: Notarize the DMG
# ============================================
if [ -z "$SKIP_NOTARIZATION" ]; then
    echo "=== Step 3: Notarizing DMG ==="

    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$KEYCHAIN_PROFILE" \
        --wait

    xcrun stapler staple "$DMG_PATH"
    echo "DMG notarized!"
    echo ""
fi

# ============================================
# Step 4: Sign for Sparkle and generate appcast
# ============================================
echo "=== Step 4: Signing for Sparkle ==="

# Find Sparkle tools
SPARKLE_SIGN=""
GENERATE_APPCAST=""

POSSIBLE_PATHS=(
    "$HOME/Library/Developer/Xcode/DerivedData/ClaudeIsland-*/SourcePackages/artifacts/sparkle/Sparkle/bin"
)

for path_pattern in "${POSSIBLE_PATHS[@]}"; do
    for path in $path_pattern; do
        if [ -x "$path/sign_update" ]; then
            SPARKLE_SIGN="$path/sign_update"
            GENERATE_APPCAST="$path/generate_appcast"
            break 2
        fi
    done
done

if [ -z "$SPARKLE_SIGN" ]; then
    echo "WARNING: Could not find Sparkle tools."
    echo "Build the project in Xcode first to download Sparkle package."
    echo ""
    echo "Skipping Sparkle signing. You'll need to manually:"
    echo "1. Sign the DMG with sign_update"
    echo "2. Generate appcast with generate_appcast"
else
    # Check for private key
    if [ ! -f "$KEYS_DIR/eddsa_private_key" ]; then
        echo "WARNING: No private key found at $KEYS_DIR/eddsa_private_key"
        echo "Run ./scripts/generate-keys.sh first"
        echo ""
        echo "Skipping Sparkle signing."
    else
        # Generate signature
        echo "Signing DMG for Sparkle..."
        SIGNATURE=$("$SPARKLE_SIGN" --ed-key-file "$KEYS_DIR/eddsa_private_key" "$DMG_PATH")

        echo ""
        echo "Sparkle signature:"
        echo "$SIGNATURE"
        echo ""

        # Generate/update appcast
        echo "Generating appcast..."
        APPCAST_DIR="$RELEASE_DIR/appcast"
        mkdir -p "$APPCAST_DIR"

        # Copy DMG to appcast directory
        cp "$DMG_PATH" "$APPCAST_DIR/"

        # Generate appcast.xml
        "$GENERATE_APPCAST" --ed-key-file "$KEYS_DIR/eddsa_private_key" "$APPCAST_DIR"

        echo "Appcast generated at: $APPCAST_DIR/appcast.xml"
    fi
fi

echo ""

# ============================================
# Step 5: Create GitHub Release
# ============================================
echo "=== Step 5: Creating GitHub Release ==="

if ! command -v gh &> /dev/null; then
    echo "WARNING: gh CLI not found. Install with: brew install gh"
    echo "Skipping GitHub release."
else
    # Check if release already exists
    if gh release view "v$VERSION" --repo "$GITHUB_REPO" &>/dev/null; then
        echo "Release v$VERSION already exists. Updating..."
        gh release upload "v$VERSION" "$DMG_PATH" --repo "$GITHUB_REPO" --clobber
    else
        echo "Creating release v$VERSION..."
        gh release create "v$VERSION" "$DMG_PATH" \
            --repo "$GITHUB_REPO" \
            --title "Claude Island v$VERSION" \
            --notes "## Claude Island v$VERSION

### Installation
1. Download \`$APP_NAME-$VERSION.dmg\`
2. Open the DMG and drag Claude Island to Applications
3. Launch Claude Island from Applications

### Auto-updates
After installation, Claude Island will automatically check for updates."
    fi

    GITHUB_DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/v$VERSION/$APP_NAME-$VERSION.dmg"
    echo "GitHub release created: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
    echo "Download URL: $GITHUB_DOWNLOAD_URL"
fi

echo ""

# ============================================
# Step 6: Update website appcast and deploy
# ============================================
echo "=== Step 6: Updating Website ==="

if [ -d "$WEBSITE_PUBLIC" ] && [ -f "$RELEASE_DIR/appcast/appcast.xml" ]; then
    # Copy appcast to website
    cp "$RELEASE_DIR/appcast/appcast.xml" "$WEBSITE_PUBLIC/appcast.xml"

    # Update the download URL in appcast to point to GitHub releases
    if [ -n "$GITHUB_DOWNLOAD_URL" ]; then
        sed -i '' "s|url=\"[^\"]*$APP_NAME-$VERSION.dmg\"|url=\"$GITHUB_DOWNLOAD_URL\"|g" "$WEBSITE_PUBLIC/appcast.xml"
        echo "Updated appcast.xml with GitHub download URL"
    fi

    # Commit and push website changes
    cd "$WEBSITE_DIR"
    if [ -d ".git" ]; then
        git add public/appcast.xml
        if ! git diff --cached --quiet; then
            git commit -m "Update appcast for v$VERSION"
            echo "Committed appcast update"

            read -p "Push website changes to deploy? (Y/n) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                git push
                echo "Website deployed!"
            else
                echo "Changes committed but not pushed. Run 'git push' in $WEBSITE_DIR to deploy."
            fi
        else
            echo "No changes to commit"
        fi
    else
        echo "Copied appcast.xml to $WEBSITE_PUBLIC/"
        echo "Note: Website directory is not a git repo"
    fi
    cd "$PROJECT_DIR"
else
    echo "Website directory not found or appcast not generated"
    echo "Skipping website update."
fi

echo ""

echo "=== Release Complete ==="
echo ""
echo "Files created:"
echo "  - DMG: $DMG_PATH"
if [ -f "$RELEASE_DIR/appcast/appcast.xml" ]; then
    echo "  - Appcast: $RELEASE_DIR/appcast/appcast.xml"
fi
if [ -n "$GITHUB_DOWNLOAD_URL" ]; then
    echo "  - GitHub: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
fi
if [ -f "$WEBSITE_PUBLIC/appcast.xml" ]; then
    echo "  - Website: $WEBSITE_PUBLIC/appcast.xml"
fi
