#!/usr/bin/env bash
cd "$(dirname "$0")/ios"
if [ $# -gt 0 ]; then
    files=()
    for f in "$@"; do
        files+=("${f#ios/}")
    done
    swiftlint lint --strict --quiet "${files[@]}"
else
    swiftlint lint --strict --quiet
fi
