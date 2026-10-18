#!/usr/bin/env bash

set -euo pipefail

module_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$module_root"
make -j"${TEST_BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN)}" \
    CFLAGS="-O2 -g -fPIC -I/usr/include/luajit-2.1"
export LUA_PATH="$module_root/.ci/telescope/?.lua;;"
export LUA_CPATH="$module_root/?.so;;"
luajit .ci/telescope/tsc spec/lolhtml.lua
