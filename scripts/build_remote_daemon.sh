#!/usr/bin/env bash
# Build namud-remote for all supported platforms and generate the manifest JSON.
# Usage: ./scripts/build_remote_daemon.sh [version]
#
# Outputs:
#   build/remote-daemon/<version>/<os>-<arch>/namud-remote  (binaries)
#   build/remote-daemon/manifest.json                       (manifest)
#
# CI/Release integration:
#   After the Xcode build, run this script and inject the manifest into Info.plist:
#
#     APP_PLIST="build/Build/Products/Release/Namu.app/Contents/Info.plist"
#     APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PLIST")
#     ./scripts/build_remote_daemon.sh "$APP_VERSION"
#     MANIFEST_JSON="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), separators=(",",":")))' build/remote-daemon/manifest.json)"
#     plutil -remove NamuRemoteDaemonManifestJSON "$APP_PLIST" >/dev/null 2>&1 || true
#     plutil -insert NamuRemoteDaemonManifestJSON -string "$MANIFEST_JSON" "$APP_PLIST"
set -euo pipefail

VERSION="${1:-dev}"
if [[ ! "$VERSION" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "Error: Invalid version string: $VERSION" >&2
    exit 1
fi
SOURCE_DIR="daemon/remote/cmd/namud-remote"
OUTPUT_DIR="build/remote-daemon"
MANIFEST_FILE="$OUTPUT_DIR/manifest.json"

# Platforms to build for
PLATFORMS=(
    "linux:amd64"
    "linux:arm64"
    "darwin:amd64"
    "darwin:arm64"
)

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

ENTRIES=""

for platform in "${PLATFORMS[@]}"; do
    IFS=':' read -r goos goarch <<< "$platform"
    binary_dir="$OUTPUT_DIR/$VERSION/$goos-$goarch"
    mkdir -p "$binary_dir"
    binary_path="$binary_dir/namud-remote"

    echo "Building namud-remote for $goos/$goarch..."
    GOOS="$goos" GOARCH="$goarch" CGO_ENABLED=0 go build \
        -ldflags="-s -w -X main.version=$VERSION" \
        -trimpath \
        -o "$binary_path" \
        "./$SOURCE_DIR"

    sha256=$(shasum -a 256 "$binary_path" | awk '{print $1}')

    if [ -n "$ENTRIES" ]; then
        ENTRIES="$ENTRIES,"
    fi
    ENTRIES="$ENTRIES
    {
      \"goOS\": \"$goos\",
      \"goArch\": \"$goarch\",
      \"assetName\": \"namud-remote-$goos-$goarch\",
      \"downloadURL\": \"\",
      \"sha256\": \"$sha256\"
    }"
done

cat > "$MANIFEST_FILE" <<MANIFEST
{
  "schemaVersion": 1,
  "appVersion": "$VERSION",
  "releaseTag": "v$VERSION",
  "releaseURL": "",
  "checksumsAssetName": "checksums.txt",
  "checksumsURL": "",
  "entries": [$ENTRIES
  ]
}
MANIFEST

echo "Manifest written to $MANIFEST_FILE"
echo "Done. Built ${#PLATFORMS[@]} binaries."
