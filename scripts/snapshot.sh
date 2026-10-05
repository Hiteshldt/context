#!/bin/zsh
# Renders screenshots of every screen with demo data (in a temporary directory) for visual review.
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
OUT="${1:-$PWD/.build/snapshots}"
mkdir -p .build/snapshot-main "$OUT"
# Top-level code must live in a file named main.swift.
cp scripts/snapshot.swift .build/snapshot-main/main.swift
swiftc -module-cache-path "$CLANG_MODULE_CACHE_PATH" -o .build/context-snapshot $(ls Sources/Context/*.swift | grep -v ContextApp.swift) .build/snapshot-main/main.swift
.build/context-snapshot "$OUT"
