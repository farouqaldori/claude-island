#!/bin/bash
# Generate EdDSA signing keys for Sparkle updates
# Run this ONCE and save the private key securely!

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
KEYS_DIR="$PROJECT_DIR/.sparkle-keys"

echo "=== Sparkle EdDSA Key Generation ==="
echo ""

# Check if keys already exist
if [ -f "$KEYS_DIR/eddsa_private_key" ]; then
    echo "WARNING: Keys already exist at $KEYS_DIR"
    echo "If you regenerate keys, existing users won't be able to update!"
    read -p "Do you want to regenerate? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

mkdir -p "$KEYS_DIR"

# Find Sparkle's generate_keys tool
# First check if it's in DerivedData from SPM build
GENERATE_KEYS=""

# Check common locations
POSSIBLE_PATHS=(
    "$HOME/Library/Developer/Xcode/DerivedData/ClaudeIsland-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys"
    "/usr/local/bin/generate_keys"
    "$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
)

for path_pattern in "${POSSIBLE_PATHS[@]}"; do
    for path in $path_pattern; do
        if [ -x "$path" ]; then
            GENERATE_KEYS="$path"
            break 2
        fi
    done
done

if [ -z "$GENERATE_KEYS" ]; then
    echo "Could not find Sparkle's generate_keys tool."
    echo ""
    echo "You need to:"
    echo "1. Build the project in Xcode first (to download Sparkle package)"
    echo "2. Or download Sparkle manually from:"
    echo "   https://github.com/sparkle-project/Sparkle/releases"
    echo ""
    echo "After downloading, run:"
    echo "   /path/to/Sparkle/bin/generate_keys -p > $KEYS_DIR/eddsa_private_key"
    echo ""
    echo "Then run this script again to extract the public key."
    exit 1
fi

echo "Using generate_keys from: $GENERATE_KEYS"
echo ""

# Generate the key pair (stores in Keychain, prints public key)
echo "Generating EdDSA key pair..."
PUBLIC_KEY=$("$GENERATE_KEYS" | grep -oE '[A-Za-z0-9+/=]{40,}')

# Export private key to file
echo "Exporting private key to file..."
"$GENERATE_KEYS" -x "$KEYS_DIR/eddsa_private_key"

echo ""
echo "=== IMPORTANT ==="
echo ""
echo "Private key saved to: $KEYS_DIR/eddsa_private_key"
echo "KEEP THIS FILE SECURE! Add it to .gitignore!"
echo ""
echo "Your PUBLIC key (add this to Info.plist as SUPublicEDKey):"
echo ""
echo "  $PUBLIC_KEY"
echo ""
echo "The private key has also been added to your macOS Keychain."
echo ""

# Add to .gitignore if not already there
if ! grep -q ".sparkle-keys" "$PROJECT_DIR/.gitignore" 2>/dev/null; then
    {
        echo ""
        echo "# Sparkle signing keys (NEVER commit these!)"
        echo ".sparkle-keys/"
    } >> "$PROJECT_DIR/.gitignore"
    echo "Added .sparkle-keys/ to .gitignore"
fi

echo ""
echo "Next steps:"
echo "1. Update Info.plist with the public key above"
echo "2. Run ./scripts/build.sh to build a release"
echo "3. Run ./scripts/create-release.sh to create a signed DMG and appcast"
