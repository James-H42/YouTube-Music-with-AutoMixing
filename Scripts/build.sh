#!/bin/zsh
# Compiles the package and prints a condensed list of compiler errors.
cd "$(dirname "$0")/.."
swift build -c "${1:-debug}" 2>&1 | grep -E "error|Build complete|Compiling|warning: var|warning: unused" | sed -E 's/: FixIt\(.*//; s|.*/Sources/Metrolist/||' | grep -v "SwiftDriver\|builtin-\|^error: Build failed" | cut -c1-260 | sort -u | head -${2:-40}
