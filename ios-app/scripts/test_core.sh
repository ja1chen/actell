#!/bin/bash
set -euo pipefail
remote=0
if [ "${1:-}" = --remote ]; then remote=1; shift; fi
if [ "$#" -lt 1 ]; then echo "Usage: $0 [--remote] <isolated-simulator-UDID> [TestClass[/testMethod] ...] (RUN_UI_TESTS=1 includes this domain's UI)" >&2; exit 2; fi
simulator="$1"; shift
scheme=PhoneAgent
target=PhoneAgentTests
ui_target=PhoneAgentUITests
if [ "$remote" = 1 ]; then
  scheme=PhoneAgentRemote
  target=RemoteTests
  ui_target=RemoteUITests
fi
selection=()
for selector in "$@"; do
  if [[ ! "$selector" =~ ^[A-Za-z_][A-Za-z0-9_]*(/[A-Za-z_][A-Za-z0-9_]*)?$ ]]; then
    echo "Use a test class or Class/testMethod within $target: $selector" >&2; exit 2
  fi
  selection+=("-only-testing:$target/$selector")
done
if [ "${#selection[@]}" = 0 ]; then selection=("-only-testing:$target"); fi
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
python3 "$repo_root/ios-app/scripts/check_localizations.py"
mkdir -p "$repo_root/.build/validation"
result_dir="$(mktemp -d "$repo_root/.build/validation/core.XXXXXX")"
echo "Test scheme: $scheme; selection: ${selection[*]}"
# Opt-in local simulator signing enables real Keychain/TLS identity tests.
# This does not select a developer team or change project signing settings.
signing=(CODE_SIGNING_ALLOWED=NO)
if [ "${SIMULATOR_ADHOC_SIGN:-0}" = 1 ]; then
  signing=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES)
fi
if [ "${RUN_UI_TESTS:-0}" = 1 ]; then
  python3 "$repo_root/ios-app/scripts/prepare_ui_fixtures.py" "$simulator"
  selection+=("-only-testing:$ui_target")
fi
xcodebuild -project "$repo_root/ios-app/PhoneAgent.xcodeproj" -scheme "$scheme" \
  -destination "platform=iOS Simulator,id=$simulator" -derivedDataPath "${PHONEAGENT_DERIVED_DATA_PATH:-$repo_root/.build/DerivedData}" \
  -clonedSourcePackagesDirPath "$repo_root/.build/SourcePackages" \
  -disableAutomaticPackageResolution -skipPackageUpdates -parallel-testing-enabled NO \
  -resultBundlePath "$result_dir/Tests.xcresult" "${selection[@]}" \
  "${signing[@]}" test > "$result_dir/test.log" 2>&1 || { tail -50 "$result_dir/test.log"; exit 1; }
tail -12 "$result_dir/test.log"
echo "Evidence: $result_dir"
