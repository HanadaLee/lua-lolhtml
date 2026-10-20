#!/usr/bin/env bash

set -euo pipefail

prefix="${1:?Usage: setup-luarocks.sh <install-prefix>}"
version=3.13.0
build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT

curl -fSL --retry 3 --connect-timeout 15 --max-time 120 \
    "https://luarocks.github.io/luarocks/releases/luarocks-${version}.tar.gz" \
    -o "$build_dir/luarocks.tar.gz"
tar -xzf "$build_dir/luarocks.tar.gz" -C "$build_dir"
cd "$build_dir/luarocks-${version}"
./configure --prefix="$prefix" --with-lua=/usr \
    --with-lua-include=/usr/include/luajit-2.1 \
    --lua-version=5.1 --with-lua-interpreter=luajit
make
make install
