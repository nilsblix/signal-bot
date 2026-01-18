#!/usr/bin/env bash

set -ex
zig build test --summary all
zig fmt .
zig build
