#!/usr/bin/env bash

set -ex
find src -name "*.zig" | xargs -I {} zig test {}
zig fmt .
zig build
