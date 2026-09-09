#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: build-release-assets.sh <version> <output-directory>" >&2
  exit 2
fi

version="$1"
output_directory="$2"

if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]; then
  echo "Release version '$version' is not a supported semantic version." >&2
  exit 1
fi

if [[ -e "$output_directory" && ! -d "$output_directory" ]]; then
  echo "Release output path is not a directory: $output_directory" >&2
  exit 1
fi

mkdir -p "$output_directory"
if [[ -n "$(find "$output_directory" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  echo "Release output directory must be empty: $output_directory" >&2
  exit 1
fi

if [[ ! -f edge/dist/index.js ]]; then
  echo "Edge build output is missing. Run the Edge build first." >&2
  exit 1
fi

stage_directory="$(mktemp -d)"
cleanup() {
  rm -rf -- "$stage_directory"
}
trap cleanup EXIT

ldflags="-s -w -buildid= -X main.version=${version}"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -buildvcs=true -ldflags="$ldflags" -o "$output_directory/shieldwardd-linux-amd64" ./cmd/shieldwardd
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -buildvcs=true -ldflags="$ldflags" -o "$output_directory/shieldwardd-linux-arm64" ./cmd/shieldwardd
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -buildvcs=true -ldflags="$ldflags" -o "$output_directory/shieldwardd-windows-amd64.exe" ./cmd/shieldwardd
CGO_ENABLED=0 GOOS=windows GOARCH=arm64 go build -trimpath -buildvcs=true -ldflags="$ldflags" -o "$output_directory/shieldwardd-windows-arm64.exe" ./cmd/shieldwardd

mkdir -p "$stage_directory/edge"
cp -R edge/dist "$stage_directory/edge/dist"
cp edge/package.json edge/package-lock.json "$stage_directory/edge/"
tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner -C "$stage_directory" edge \
  | gzip -n > "$output_directory/shieldward-edge-${version}.tar.gz"
