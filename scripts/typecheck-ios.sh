#!/usr/bin/env bash
# Typechecks SpudCore and the app against the iPhone SDK without needing the iOS
# platform download, a simulator or signing. Usage: scripts/typecheck-ios.sh [scratch-dir]
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-${TMPDIR:-/tmp}/spudgungolf-typecheck}"
mkdir -p "$OUT"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
T=(-target arm64-apple-ios17.0 -sdk "$SDK")
S=Packages/SpudCore/Sources

# SwiftPM generates Bundle.module for resources; stand it in for a bare swiftc build.
printf 'import Foundation\nextension Bundle { static var module: Bundle { .main } }\n' > "$OUT/BundleStub.swift"

module() { # name, extra files...
  local name="$1"; shift
  xcrun --sdk iphoneos swiftc -emit-module -module-name "$name" "${T[@]}" -parse-as-library -I "$OUT" \
    -emit-module-path "$OUT/$name.swiftmodule" "$S/$name"/*.swift "$@"
}

module CoreGeo
module SafetyKit "$OUT/BundleStub.swift"
module RangingKit
module CourseKit

# shellcheck disable=SC2046
xcrun --sdk iphoneos swiftc -typecheck -module-name SpudGunGolf "${T[@]}" -I "$OUT" -swift-version 5 \
  $(find App/Sources -name '*.swift')

echo "iOS typecheck passed"
