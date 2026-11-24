#!/bin/bash
set -euo pipefail

repository=pachi-33/Mindscape
bundle_id=com.youyanping.mindscape
feed=https://raw.githubusercontent.com/pachi-33/Mindscape/main/updates/appcast.xml

: "${RELEASE_COMMIT:?Set RELEASE_COMMIT to the verified, full main commit SHA}"
: "${RELEASE_IDENTITY:?Set RELEASE_IDENTITY to the Developer ID Application identity}"
: "${RELEASE_TEAM:?Set RELEASE_TEAM to the Apple Developer team ID}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to the notarytool Keychain profile}"
: "${SPARKLE_ACCOUNT:?Set SPARKLE_ACCOUNT to the Sparkle signing Keychain account}"

[[ "$RELEASE_IDENTITY" == "Developer ID Application:"* ]]
[[ "$RELEASE_TEAM" =~ ^[A-Z0-9]{10}$ ]]
[[ "$RELEASE_COMMIT" =~ ^[a-f0-9]{40}$ ]]
[[ "$(git rev-parse HEAD)" == "$RELEASE_COMMIT" && -z "$(git status --porcelain)" ]] || {
    echo "Build from a clean checkout at RELEASE_COMMIT" >&2
    exit 1
}
[[ "$(gh api "repos/$repository/branches/main" --jq .commit.sha)" == "$RELEASE_COMMIT" ]] || {
    echo "RELEASE_COMMIT must be the current remote main" >&2
    exit 1
}

version="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' project.yml)"
build="$(awk -F'"' '/CURRENT_PROJECT_VERSION:/ {print $2; exit}' project.yml)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[[:alnum:]]+([.-][[:alnum:]]+)*)?$ ]]
[[ "$build" =~ ^[1-9][0-9]*$ ]]
tag="v$version"
set --
if [[ "$version" == *-* ]]; then set -- --prerelease; fi
if [[ -n "$(git ls-remote --tags "https://github.com/$repository.git" "refs/tags/$tag")" ]]; then
    echo "The remote tag already exists. Use a new release version." >&2
    exit 1
fi

mkdir -p dist
dist="$(mktemp -d "$PWD/dist/release.XXXXXXXX")"
trap 'printf "Release files: %s\n" "$dist"' EXIT
notes="$dist/release-notes.md"
awk -v heading="## [$version]" 'index($0, heading)==1 {active=1; next} active && /^## \[/ {exit} active {print}' CHANGELOG.md > "$notes"
[[ -s "$notes" ]] || { echo "Missing changelog entry for $version" >&2; exit 1; }

xcodegen generate
xcodebuild -resolvePackageDependencies -project Mindscape.xcodeproj -scheme Mindscape \
    -clonedSourcePackagesDirPath "$dist/packages"
tools="$dist/packages/artifacts/sparkle/Sparkle/bin"
public_key="$("$tools/generate_keys" --account "$SPARKLE_ACCOUNT" -p)"
[[ "$public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo "Missing Sparkle public key" >&2; exit 1; }

xcodebuild build -project Mindscape.xcodeproj -scheme Mindscape -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$dist/build" \
    -clonedSourcePackagesDirPath "$dist/packages" -disableAutomaticPackageResolution \
    ONLY_ACTIVE_ARCH=NO 'ARCHS=arm64 x86_64' CODE_SIGNING_ALLOWED=NO \
    "MINDSCAPE_UPDATE_PUBLIC_KEY=$public_key"

app="$dist/build/Build/Products/Release/Mindscape.app"
framework="$app/Contents/Frameworks/Sparkle.framework/Versions/Current"
# Ensure the install helpers and application share the distribution identity.
for component in "$framework/Autoupdate" "$framework/Updater.app" "$framework/XPCServices/"*.xpc \
    "$app/Contents/Frameworks/Sparkle.framework" "$app"; do
    codesign --force --timestamp --options runtime --sign "$RELEASE_IDENTITY" "$component"
done
plist="$app/Contents/Info.plist"
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist"; }
[[ "$(plist_value CFBundleIdentifier)" == "$bundle_id" ]]
[[ "$(plist_value CFBundleShortVersionString)" == "$version" && "$(plist_value CFBundleVersion)" == "$build" ]]
[[ "$(plist_value SUFeedURL)" == "$feed" && "$(plist_value SUPublicEDKey)" == "$public_key" ]]
codesign --verify --deep --strict "$app"
codesign --display --verbose=4 "$app" 2>&1 | grep -qx "TeamIdentifier=$RELEASE_TEAM"
lipo -verify_arch arm64 x86_64 "$app/Contents/MacOS/Mindscape"

notary_zip="$dist/notarize.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$notary_zip"
xcrun notarytool submit "$notary_zip" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$dist/notary-result.json"
python3 -c 'import json,sys; sys.exit(json.load(open(sys.argv[1])).get("status") != "Accepted")' "$dist/notary-result.json"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"

zip="$dist/Mindscape-$version.zip"
dmg="$dist/Mindscape-$version.dmg"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
mkdir "$dist/staging"
ditto "$app" "$dist/staging/Mindscape.app"
ln -s /Applications "$dist/staging/Applications"
hdiutil create -volname "Mindscape $version" -srcfolder "$dist/staging" -format UDZO "$dmg"
(cd "$dist" && shasum -a 256 "Mindscape-$version.dmg" > "Mindscape-$version.dmg.sha256")

feed_args=(--output "$dist/appcast.xml")
if git cat-file -e HEAD:updates/appcast.xml 2>/dev/null; then
    git show HEAD:updates/appcast.xml > "$dist/previous.xml"
    feed_args+=(--previous "$dist/previous.xml")
fi
python3 scripts/update-appcast.py --archive "$zip" --notes "$notes" --version "$version" --build "$build" \
    --minimum-system "$(plist_value LSMinimumSystemVersion)" --sign-tool "$tools/sign_update" \
    --account "$SPARKLE_ACCOUNT" "${feed_args[@]}"

gh release create "$tag" "$zip" "$dmg" "$dmg.sha256" --repo "$repository" --target "$RELEASE_COMMIT" \
    --title "Mindscape $version" --notes-file "$notes" --draft "$@"
gh release download "$tag" --repo "$repository" --pattern "Mindscape-$version.zip" --output "$dist/draft.zip"
cmp "$zip" "$dist/draft.zip"
gh release edit "$tag" --repo "$repository" --draft=false
python3 scripts/verify-update-asset.py "$zip" "$version" "$dist/remote.zip"

# Stage only after verifying that the exact archive can be fetched without credentials.
[[ "$(gh api "repos/$repository/branches/main" --jq .commit.sha)" == "$RELEASE_COMMIT" ]] || {
    echo "Remote main changed during publishing. Reconcile the signed feed before updating it." >&2
    exit 1
}
mkdir -p updates
cp "$dist/appcast.xml" updates/appcast.xml
printf 'Verified %s. Commit updates/appcast.xml and merge it to main to enable in-app discovery.\n' "$tag"
