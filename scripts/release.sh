#!/bin/sh
# Release lidless: tag, push, and publish the Homebrew formula to vitkon/homebrew-tap.
# usage: scripts/release.sh 1.1.0
set -eu
VERSION=${1:?usage: scripts/release.sh <version>}
REPO=vitkon/lidless
TAP=vitkon/homebrew-tap
cd "$(dirname "$0")/.."

grep -q "\"$VERSION\"" Sources/lidless/Version.swift || { echo "Version.swift is not $VERSION"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "working tree not clean"; exit 1; }
swift test

git tag -a "v$VERSION" -m "lidless $VERSION"
git push origin main "v$VERSION"

URL="https://github.com/$REPO/archive/refs/tags/v$VERSION.tar.gz"
SHA=$(curl -fsSL "$URL" | shasum -a 256 | cut -d' ' -f1)
echo "tarball sha256: $SHA"

WORK=$(mktemp -d)
gh repo clone "$TAP" "$WORK/tap" -- --depth 1
mkdir -p "$WORK/tap/Formula"
sed -e "s|@VERSION@|$VERSION|g" -e "s|@SHA256@|$SHA|g" packaging/lidless.rb.in > "$WORK/tap/Formula/lidless.rb"
cd "$WORK/tap"
git add Formula/lidless.rb
git commit -m "lidless $VERSION"
git push
echo "published: brew install vitkon/tap/lidless"
