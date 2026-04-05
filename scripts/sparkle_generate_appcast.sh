#!/bin/bash
set -euo pipefail

# Generate a Sparkle appcast.xml for a DMG release.
# Usage: sparkle_generate_appcast.sh <dmg-path> <tag> <output-path>
#
# Requires: SPARKLE_PRIVATE_KEY env var (Ed25519 private key)

DMG_PATH="$1"
TAG="$2"
OUTPUT="$3"

if [ -z "${SPARKLE_PRIVATE_KEY:-}" ]; then
  echo "Error: SPARKLE_PRIVATE_KEY environment variable is required" >&2
  exit 1
fi

VERSION="${TAG#v}"
DMG_SIZE=$(stat -f%z "$DMG_PATH")
DMG_DATE=$(date -R)

# Generate Ed25519 signature using Sparkle's sign_update tool if available,
# otherwise use openssl.
if command -v sign_update >/dev/null 2>&1; then
  SIGNATURE=$(echo -n "$SPARKLE_PRIVATE_KEY" | sign_update "$DMG_PATH" -f -)
else
  SIGNATURE=$(echo -n "$SPARKLE_PRIVATE_KEY" | base64 -d | openssl pkeyutl -sign -inkey /dev/stdin -rawin -in <(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1 | xxd -r -p) 2>/dev/null | base64)
fi

DOWNLOAD_URL="https://github.com/namu-sh/namu/releases/download/${TAG}/namu-macos.dmg"

cat > "$OUTPUT" << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Namu Updates</title>
    <link>https://github.com/namu-sh/namu/releases/latest/download/appcast.xml</link>
    <description>Namu terminal multiplexer updates</description>
    <language>en</language>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${DMG_DATE}</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure
        url="${DOWNLOAD_URL}"
        length="${DMG_SIZE}"
        type="application/octet-stream"
        sparkle:edSignature="${SIGNATURE}"
      />
    </item>
  </channel>
</rss>
EOF

echo "Generated appcast.xml for ${VERSION} (${DMG_SIZE} bytes)"
