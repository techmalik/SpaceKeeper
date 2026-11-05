#!/bin/bash
# Runs regression tests with Xcode Command Line Tools; XCTest/full Xcode is not required.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/regression
sources=()
for source in Sources/SpaceKeeper/*.swift; do
    [[ "$source" == "Sources/SpaceKeeper/main.swift" ]] || sources+=("$source")
done
swiftc -parse-as-library -swift-version 5 "${sources[@]}" Tests/SpaceKeeperTests/AuditRegressionTests.swift \
    -framework Carbon -framework ScreenCaptureKit -framework ServiceManagement -o .build/regression/tests
.build/regression/tests
