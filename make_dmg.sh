#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  make_dmg.sh — build a native drag-and-drop macOS installer
#
#  Usage:
#    ./make_dmg.sh
#
#  Produces SalukaKey-v1.2.0.dmg: a compressed UDZO disk image whose
#  Finder window shows the app on the left, an arrow, and an
#  /Applications alias on the right, over a generated banner.
# ══════════════════════════════════════════════════════════════

set -euo pipefail

APP_NAME="SalukaKey"
VOL_NAME="SalukaKey"
BG_DIR=".background"
BG_TOOL="Tools/make_dmg_background.swift"

WIDTH=600
HEIGHT=400
ICON_SIZE=128
APP_POS="170, 190"
LINK_POS="440, 190"
VOLUME_SIZE=100m

cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
DMG_FILE="${APP_NAME}-v${VERSION}.dmg"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/salukakey-dmg.XXXXXX")
TEMP_DMG="${WORK_DIR}/temp.dmg"
MOUNT_POINT=""

# Finder stores the "show hidden files" state of a disk window inside the
# volume's .DS_Store, so the window is laid out with hidden files switched
# off — that keeps the banner folder out of the window for every user,
# even those who run Finder with hidden files visible. The preference is
# restored afterwards.
SHOW_ALL_ORIGINAL=$(defaults read com.apple.finder AppleShowAllFiles 2>/dev/null || echo "false")
case "$(echo "${SHOW_ALL_ORIGINAL}" | tr '[:upper:]' '[:lower:]')" in
    1 | true | yes) SHOW_ALL_ORIGINAL="true" ;;
    *)              SHOW_ALL_ORIGINAL="false" ;;
esac

cleanup() {
    if [ -n "${MOUNT_POINT}" ] && [ -d "${MOUNT_POINT}" ]; then
        hdiutil detach "${MOUNT_POINT}" -force >/dev/null 2>&1 || true
    fi
    rm -rf "${WORK_DIR}"
    defaults write com.apple.finder AppleShowAllFiles -bool "${SHOW_ALL_ORIGINAL}" >/dev/null 2>&1 || true
    killall Finder >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ── 1. Build & ad-hoc sign the app ──────────────────────────────────
if [ ! -d "${APP_NAME}.app" ]; then
    echo "🔨 ${APP_NAME}.app not found — building it first ..."
    ./build.sh
fi

BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_NAME}.app/Contents/Info.plist")
if [ "${BUNDLE_VERSION}" != "${VERSION}" ]; then
    echo "🔨 Bundle version ${BUNDLE_VERSION} ≠ ${VERSION} — rebuilding ..."
    ./build.sh
fi

echo "🔏 Ad-hoc signing ${APP_NAME}.app (v${VERSION}) ..."
codesign --force --deep --sign - "${APP_NAME}.app"
codesign --verify --deep "${APP_NAME}.app" && echo "   ✓ signature valid"

# ── 2. Render the background banner ─────────────────────────────────
# Finder draws a disk background picture at one image pixel per point and
# picks up a "<name>@2x.png" sibling on Retina displays, so both a 1x and a
# 2x render are shipped.
echo "🎨 Rendering background banner (${WIDTH}x${HEIGHT}) ..."
STAGE_DIR="${WORK_DIR}/stage"
mkdir -p "${STAGE_DIR}/${BG_DIR}"
swift "${BG_TOOL}" "${STAGE_DIR}/${BG_DIR}/background.png" 1
swift "${BG_TOOL}" "${STAGE_DIR}/${BG_DIR}/background@2x.png" 2

# ── 3. Create a writable disk image and mount it ────────────────────
echo "💿 Creating writable disk image ..."
hdiutil create -volname "${VOL_NAME}" \
               -fs HFS+ \
               -fsargs "-c c=64,a=16,e=16" \
               -size "${VOLUME_SIZE}" \
               "${TEMP_DMG}" >/dev/null

defaults write com.apple.finder AppleShowAllFiles -bool false
killall Finder >/dev/null 2>&1 || true
sleep 2

ATTACH_OUTPUT=$(hdiutil attach "${TEMP_DMG}")
MOUNT_POINT=$(echo "${ATTACH_OUTPUT}" | grep -oE '/Volumes/[^ ]+$' | head -1)
if [ -z "${MOUNT_POINT}" ]; then
    echo "❌ Could not determine the mount point" >&2
    exit 1
fi
echo "   ✓ mounted at ${MOUNT_POINT}"

# ── 4. Populate the volume ──────────────────────────────────────────
echo "📦 Adding ${APP_NAME}.app and the Applications alias ..."
ditto "${APP_NAME}.app" "${MOUNT_POINT}/${APP_NAME}.app"
cp -R "${STAGE_DIR}/${BG_DIR}" "${MOUNT_POINT}/${BG_DIR}"
ln -s /Applications "${MOUNT_POINT}/Applications"

# The HFS+ hidden flag keeps the banner folder out of the window even when
# the user has "Show Hidden Files" switched on.
chflags hidden "${MOUNT_POINT}/${BG_DIR}"

# ── 5. Lay out the Finder window ────────────────────────────────────
# The background picture is only picked up once the window has been closed
# and reopened, so the window is configured, reloaded and re-configured.
echo "🪟 Configuring the Finder window ..."
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "${VOL_NAME}"
        open
        delay 2
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, $((100 + WIDTH)), $((100 + HEIGHT))}

        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to ${ICON_SIZE}
        set text size of viewOptions to 12
        set background picture of viewOptions to file ".background:background.png"

        set position of item "${APP_NAME}.app" of container window to {${APP_POS}}
        set position of item "Applications" of container window to {${LINK_POS}}

        close
        delay 1
        open
        delay 2

        set the bounds of container window to {100, 100, $((100 + WIDTH)), $((100 + HEIGHT))}
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT

# ── 6. Flush, unmount and compress ───────────────────────────────────
echo "⏳ Flushing Finder metadata ..."
sync
sleep 1

# macOS recreates .fseventsd on the mounted volume — keep it out of the window.
rm -rf "${MOUNT_POINT}/.fseventsd" 2>/dev/null || true
chflags hidden "${MOUNT_POINT}/.fseventsd" 2>/dev/null || true

echo "🔓 Unmounting ..."
hdiutil detach "${MOUNT_POINT}" >/dev/null
MOUNT_POINT=""

echo "🗜  Converting to compressed UDZO ..."
hdiutil convert "${TEMP_DMG}" -format UDZO -imagekey zlib-level=9 -o "${DMG_FILE}" >/dev/null

echo ""
echo "✅ Installer ready: ${DMG_FILE}"
ls -lh "${DMG_FILE}"
