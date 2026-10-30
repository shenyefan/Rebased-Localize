#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${1:-$project_root/build}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"

# Build the target directly so CI does not depend on a user's local schemes.
xcodebuild \
  -project "$project_root/Rebased Localize.xcodeproj" \
  -target "Rebased Localize" \
  -configuration Release \
  -sdk macosx \
  "CONFIGURATION_BUILD_DIR=$output_dir/Release" \
  "SYMROOT=$output_dir/Products" \
  "OBJROOT=$output_dir/Intermediates" \
  'ARCHS=arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

ditto -c -k --sequesterRsrc --keepParent \
  "$output_dir/Release/Rebased Localize.app" \
  "$output_dir/Rebased-Localize-macOS.zip"
