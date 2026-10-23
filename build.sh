#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  build.sh — Build SalukaKey as a proper macOS .app bundle
#
#  Usage:
#    chmod +x build.sh
#    ./build.sh
#
#  The script compiles Sources/main.swift, creates a standard
#  macOS application bundle, and optionally signs it.
# ══════════════════════════════════════════════════════════════

set -euo pipefail

APP_NAME="SalukaKey"
BUNDLE_NAME="${APP_NAME}.app"
SRC="Sources/main.swift"
PLIST="Info.plist"

# Directories inside the .app bundle
CONTENTS="${BUNDLE_NAME}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "🔨 Compiling ${SRC} ..."

# Compile the Swift source
swiftc -O \
    -o "${APP_NAME}" \
    "${SRC}" \
    -framework AppKit \
    -framework Carbon

echo "📦 Creating ${BUNDLE_NAME} ..."

# Clean previous build
rm -rf "${BUNDLE_NAME}"

# Create bundle structure
mkdir -p "${MACOS}"
mkdir -p "${RESOURCES}"

# Copy binary and Info.plist
mv "${APP_NAME}" "${MACOS}/"
cp "${PLIST}" "${CONTENTS}/Info.plist"

# Copy app icon and other resources
if [ -d Resources ]; then
    cp -R Resources/. "${RESOURCES}/"
fi

# Ad-hoc sign the bundle. Locally built apps must be signed (even with
# an empty identity) for macOS to keep Accessibility / Input Monitoring
# permissions attached to the app instead of treating it as a new binary.
if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "${BUNDLE_NAME}" >/dev/null 2>&1 || true
fi

echo "✅ Build complete: ${BUNDLE_NAME}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  To run:"
echo "    open ${BUNDLE_NAME}"
echo ""
echo "  To run from terminal (stderr):"
echo "    ./${BUNDLE_NAME}/Contents/MacOS/${APP_NAME}"
echo ""
echo "  IMPORTANT — Grant permissions:"
echo "    System Settings → Privacy & Security → Accessibility"
echo "      → add ${BUNDLE_NAME}"
echo "    System Settings → Privacy & Security → Input Monitoring"
echo "      → add ${BUNDLE_NAME}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
