#!/bin/sh
# SPDX-License-Identifier: MIT
# scripts/fetch-libs.sh -- GitHub Release から precompiled libs を取得
#
# 使用: ./scripts/fetch-libs.sh [TAG]
# TAG 省略時は "latest" (最新リリース)
#
# 環境変数:
#   HAWK_REPO -- リポジトリ owner/name (デフォルト: example/hawk)
set -e

TAG="${1:-latest}"
REPO="${HAWK_REPO:-example/hawk}"
OS=$(uname -s)
ARCH=$(uname -m)

if [ "$TAG" = "latest" ]; then
  URL="https://github.com/${REPO}/releases/latest/download/hawk-libs-${OS}-${ARCH}.tar.gz"
else
  URL="https://github.com/${REPO}/releases/download/${TAG}/hawk-libs-${OS}-${ARCH}.tar.gz"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Fetching $URL ..."
if ! curl -fsSL -o "$TMP/libs.tar.gz" "$URL"; then
  echo "Error: could not fetch $URL" >&2
  echo "Hint: set HAWK_REPO=<owner>/<repo> or build from source with 'make build-libs'" >&2
  exit 1
fi

tar xzf "$TMP/libs.tar.gz" -C .
echo "fetched libs from $TAG"
