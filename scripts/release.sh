#!/bin/sh
# Release lidsomnia.
#   scripts/release.sh 2.0.1          tag + push; CI builds bottles, creates the release, updates the tap
#   scripts/release.sh 2.0.1 --local  no CI: publish a source-only formula to the tap from this machine
set -eu
VERSION=${1:?usage: scripts/release.sh <version> [--local]}
MODE=${2:-ci}
REPO=vitkon/lidsomnia
TAP=vitkon/homebrew-tap
cd "$(dirname "$0")/.."

grep -q "\"$VERSION\"" Sources/lidsomnia/Version.swift || { echo "Version.swift is not $VERSION"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "working tree not clean"; exit 1; }
swift test

git tag -a "v$VERSION" -m "lidsomnia $VERSION"
git push origin main "v$VERSION"

if [ "$MODE" != "--local" ]; then
  echo "tag pushed; CI is building bottles: gh run watch -R $REPO"
  exit 0
fi

URL="https://github.com/$REPO/archive/refs/tags/v$VERSION.tar.gz"
SHA=$(curl -fsSL "$URL" | shasum -a 256 | cut -d' ' -f1)
echo "tarball sha256: $SHA"
WORK=$(mktemp -d)
gh repo clone "$TAP" "$WORK/tap" -- --depth 1
mkdir -p "$WORK/tap/Formula"
sed -e "s|@VERSION@|$VERSION|g" -e "s|@SHA256@|$SHA|g" packaging/lidsomnia.rb.in > "$WORK/tap/Formula/lidsomnia.rb"
cd "$WORK/tap"
git add Formula/lidsomnia.rb
git commit -m "lidsomnia $VERSION"
git push
echo "published: brew install vitkon/tap/lidsomnia"
