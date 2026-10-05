#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
mkdir -p .build
swiftc -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  Sources/Context/Models.swift Sources/Context/Schedule.swift Sources/Context/FileSystem.swift \
  Sources/Context/BrandData.swift Sources/Context/BrandCatalog.swift \
  Sources/Context/MarkdownParser.swift Sources/Context/MarkdownHighlighter.swift Sources/Context/DiagramLayout.swift \
  Sources/Context/LauncherSearch.swift Sources/Context/Backup.swift \
  Tests/ContextTests/WorkspaceTests.swift -o .build/context-tests
.build/context-tests
