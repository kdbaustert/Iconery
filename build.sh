#!/bin/bash
# Builds Iconery.app. Pass --install to copy it into /Applications and launch it.
#
# Environment:
#   CODESIGN_IDENTITY  signing identity, or - for ad-hoc; "Cmd-Tab Local" when unset, ad-hoc when
#                      that is absent. One named here that is absent fails the build.
#   ICONERY_RELEASE    1 keeps the update feed in Info.plist; release.sh sets it.
set -euo pipefail

cd "$(dirname "$0")"
APP="build/Iconery.app"

# Checked before anything builds, so a mistyped --install fails rather than quietly not installing.
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        *)
            echo "==> ERROR: unknown option \"$arg\" (the only one is --install)" >&2
            exit 1
            ;;
    esac
done

echo "==> Compiling"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Iconery"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Iconery"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# SVGO's browser build, which SVGO.swift runs in JavaScriptCore, and its MIT license.
cp Resources/svgo/svgo.browser.js "$APP/Contents/Resources/"
cp Resources/svgo/LICENSE "$APP/Contents/Resources/svgo-LICENSE"
# Prettier and its XML plugin, bundled by esbuild, which Prettier.swift runs to lay out copied
# SVG code, and the licenses of everything in the bundle.
cp Resources/prettier/prettier-xml.js "$APP/Contents/Resources/"
cp Resources/prettier/LICENSE "$APP/Contents/Resources/prettier-LICENSE"

# The icon, compiled as Xcode does it: Assets.car, read through CFBundleIconName, plus AppIcon.icns
# for anything older. The catalog's PNGs come from Resources/Icon/make-icon.sh.
echo "==> Compiling icon"
PARTIAL="$(mktemp -d)"
trap 'rm -rf "$PARTIAL"' EXIT
xcrun actool Resources/Assets.xcassets \
    --compile "$APP/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$PARTIAL/partial.plist" >/dev/null
if [[ ! -f "$APP/Contents/Resources/Assets.car" ]]; then
    echo "==> ERROR: actool did not produce Assets.car" >&2
    exit 1
fi

# Sparkle. SwiftPM links it as @rpath/Sparkle.framework but leaves it under .build, so without this
# the app launches and dies on dyld's "Library not loaded". cp -R keeps the framework's Versions
# symlinks, which its signature covers.
echo "==> Embedding Sparkle"
SPARKLE_FW="$(find .build/artifacts -path '*/Sparkle.xcframework/macos-*/Sparkle.framework' \
    -type d -print -quit)"
if [[ -z "$SPARKLE_FW" ]]; then
    echo "==> ERROR: Sparkle.framework not found; run 'swift package resolve'" >&2
    exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
# No `grep -q`, for the same SIGPIPE reason as the identity check below.
if ! otool -l "$APP/Contents/MacOS/Iconery" | grep -F '@executable_path/../Frameworks' >/dev/null
then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Iconery"
fi

# Only release.sh sets ICONERY_RELEASE=1. Any other build would find the published version newer
# than the working tree and offer to replace what you're testing with it. Not plain RELEASE: this
# Mac's tool environment already exports RELEASE=1, which kept the feed in every build.
if [[ "${ICONERY_RELEASE:-0}" != 1 ]]; then
    /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP/Contents/Info.plist"
fi

# A library or backup folder in Documents or iCloud Drive makes macOS ask for access, and it keys
# that grant to the app's designated requirement. A stable certificate keeps the requirement the
# same build to build; ad-hoc ties it to the code hash, so every rebuild would ask again. Cmd-Tab's
# self-signed certificate, as DockIt used before it had its own. No `grep -q`: under pipefail an
# early exit can SIGPIPE `security` and fail the check. -v lists only identities codesign will
# accept, so an expired certificate falls back to ad-hoc rather than failing at codesign. A name is
# matched in its quotes, so a longer name containing it doesn't pass; a hash between spaces.
IDENTITY="${CODESIGN_IDENTITY:-Cmd-Tab Local}"
if [[ "$IDENTITY" != "-" ]] \
    && ! security find-identity -v -p codesigning \
        | grep -F -e "\"$IDENTITY\"" -e " $IDENTITY " >/dev/null; then
    if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
        echo "==> ERROR: \"$IDENTITY\" is not a code signing identity in the keychain" >&2
        exit 1
    fi
    echo "==> \"$IDENTITY\" not found; signing ad-hoc, so folder access is asked again each build"
    IDENTITY="-"
fi
echo "==> Signing as \"$IDENTITY\""
# Inside out, in the order Sparkle's documentation gives: each seal covers the ones inside it, so
# signing a part after its container breaks the container's signature. Downloader keeps its
# entitlements, which re-signing would otherwise drop.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --sign "$IDENTITY" "$SPARKLE/XPCServices/Installer.xpc"
codesign --force --sign "$IDENTITY" --preserve-metadata=entitlements \
    "$SPARKLE/XPCServices/Downloader.xpc"
codesign --force --sign "$IDENTITY" "$SPARKLE/Autoupdate"
codesign --force --sign "$IDENTITY" "$SPARKLE/Updater.app"
codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Built $APP"

if [[ "$INSTALL" == 1 ]]; then
    echo "==> Installing to /Applications"
    osascript -e 'quit app "Iconery"' 2>/dev/null || true
    for _ in $(seq 1 30); do
        pgrep -x Iconery >/dev/null 2>&1 || break
        sleep 0.1
    done
    pkill -9 -x Iconery 2>/dev/null || true
    # Copied beside the old copy first, so a failed copy leaves it installed. Not named *.app, so
    # nothing registers the half-copied bundle.
    STAGED="/Applications/.Iconery-installing"
    rm -rf "$STAGED"
    cp -R "$APP" "$STAGED"
    rm -rf /Applications/Iconery.app
    mv "$STAGED" /Applications/Iconery.app
    open /Applications/Iconery.app
    echo "==> Launched."
fi
