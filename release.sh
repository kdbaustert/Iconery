#!/bin/bash
# Publishes the version in Resources/Info.plist: the zipped app to a GitHub release, and an appcast
# entry to the gh-pages branch that SUFeedURL reads, so installed copies offer the update.
#
# Before running it, raise CFBundleShortVersionString and CFBundleVersion in Resources/Info.plist,
# then commit and push. Sparkle offers an update only when its CFBundleVersion is higher than the
# installed copy's.
#
# Usage:
#   ./release.sh NOTES.md            build, sign and publish, with NOTES.md as the release notes
#   ./release.sh NOTES.md --dry-run  stop before publishing; the files are left in build/release
#
# The appcast is signed with the EdDSA key in the login keychain under the account "Iconery",
# whose public half is SUPublicEDKey, or with SPARKLE_KEY_FILE when that's set. Back it up with:
#   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account Iconery -x <file>
set -euo pipefail

cd "$(dirname "$0")"
REPO="kdbaustert/Iconery"
APP="build/Iconery.app"
STAGING="build/release"

NOTES="${1:-}"
DRY_RUN=0
case "${2:-}" in
    --dry-run) DRY_RUN=1 ;;
    "") ;;
    *)
        echo "==> ERROR: unknown option \"$2\" (the only one is --dry-run)" >&2
        exit 1
        ;;
esac
if [[ -z "$NOTES" || ! -f "$NOTES" ]]; then
    echo "==> ERROR: pass the release notes, as Markdown: ./release.sh NOTES.md" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TAG="v$VERSION"
ARCHIVE="Iconery-$VERSION.zip"

# The release is tagged at HEAD, so HEAD has to be what gets built and already be on GitHub.
if [[ -n "$(git status --porcelain)" ]]; then
    echo "==> ERROR: the working tree has uncommitted changes; commit them first" >&2
    exit 1
fi
git fetch --quiet origin
if ! git merge-base --is-ancestor HEAD origin/main; then
    echo "==> ERROR: HEAD isn't on origin/main; push it first" >&2
    exit 1
fi
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "==> ERROR: $TAG is already released; raise the version in Resources/Info.plist" >&2
    exit 1
fi

ICONERY_RELEASE=1 ./build.sh

echo "==> Packaging $ARCHIVE"
rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGING/$ARCHIVE"
# Beside the zip under the same name, generate_appcast takes it as that version's notes.
cp "$NOTES" "$STAGING/Iconery-$VERSION.md"

# The published feed, so older entries carry over. A failed fetch stops here: generating without
# it would publish a feed listing only this release. No gh-pages branch means a first release.
if git ls-remote --exit-code --heads origin gh-pages >/dev/null; then
    git fetch --quiet origin gh-pages
    git show origin/gh-pages:appcast.xml >"$STAGING/appcast.xml"
    PARENT="$(git rev-parse origin/gh-pages)"
else
    PARENT=""
fi

echo "==> Writing the appcast"
GENERATE_APPCAST=".build/artifacts/sparkle/Sparkle/bin/generate_appcast"
# Always a named key: a bare call signs with the keychain's default account, which holds another
# app's key, and every installed Iconery would then reject the update.
APPCAST_ARGS=(--account Iconery)
if [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then
    APPCAST_ARGS=(--ed-key-file "$SPARKLE_KEY_FILE")
fi
# Only this release's zip is in the folder, so older entries stay exactly as published. No deltas:
# the release uploads only the zip.
"$GENERATE_APPCAST" \
    "${APPCAST_ARGS[@]}" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    --embed-release-notes \
    --maximum-versions 0 \
    --maximum-deltas 0 \
    "$STAGING"

if [[ "$DRY_RUN" == 1 ]]; then
    echo "==> Dry run: nothing published. See $STAGING"
    exit 0
fi

# The zip goes up before the feed names it, so no installed copy is sent to a missing file.
echo "==> Publishing $TAG"
gh release create "$TAG" "$STAGING/$ARCHIVE" --repo "$REPO" --target "$(git rev-parse HEAD)" \
    --title "Iconery $VERSION" --notes-file "$NOTES"

# Committed without a checkout, so the working tree and GitButler's workspace aren't touched.
echo "==> Publishing the appcast"
BLOB="$(git hash-object -w "$STAGING/appcast.xml")"
TREE="$(printf '100644 blob %s\tappcast.xml\n' "$BLOB" | git mktree)"
COMMIT="$(git commit-tree "$TREE" ${PARENT:+-p "$PARENT"} -m "Appcast for $VERSION")"
git push origin "$COMMIT:refs/heads/gh-pages"

# Pages serves the feed. Turned on once, by the first release.
if ! gh api "repos/$REPO/pages" >/dev/null 2>&1; then
    gh api -X POST "repos/$REPO/pages" -f 'source[branch]=gh-pages' -f 'source[path]=/' >/dev/null
fi

echo "==> Released: https://github.com/$REPO/releases/tag/$TAG"
echo "    Feed: https://kdbaustert.github.io/Iconery/appcast.xml (Pages can take a minute)"
