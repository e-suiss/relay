#!/bin/sh
# T-84
set -eu

version=12.13.0
dir="$(cd "$(dirname "$0")" && pwd)/bin"
os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
case "$arch" in
  x86_64 | amd64) arch=amd64 ;;
  arm64 | aarch64) arch=arm64 ;;
  *) echo "unsupported architecture: $arch" >&2; exit 1 ;;
esac

case "${os}_${arch}" in
  linux_amd64) sum=e8759ce45c14e18374bdccd3ba6068197bc3a9f9b7e484db3837f701b9d12e61 ;;
  linux_arm64) sum=950381173a5575e25e8e086f36fc03bf65d61a2433329b48e41e1cb5e4133bba ;;
  darwin_arm64) sum=fc408e242c4f4839e6fe536dbf1130bb02f430134827f6d831bf367a0929a799 ;;
  *) echo "unsupported platform: ${os}_${arch}" >&2; exit 1 ;;
esac

if [ -x "$dir/vegeta" ] && "$dir/vegeta" -version 2>/dev/null | grep -q "$version"; then
  exit 0
fi

archive="vegeta_${version}_${os}_${arch}.tar.gz"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/$archive" "https://github.com/tsenart/vegeta/releases/download/v${version}/${archive}"
echo "$sum  $tmp/$archive" | shasum -a 256 -c - >/dev/null
mkdir -p "$dir"
tar -xzf "$tmp/$archive" -C "$tmp" vegeta
mv "$tmp/vegeta" "$dir/vegeta"
echo "vegeta $version installed in $dir"
