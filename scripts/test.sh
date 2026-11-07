#!/bin/bash
# Run the unit tests. With only the Command Line Tools installed, Swift Testing's macro
# plugin isn't on the default search path, so point the compiler at it.
set -euo pipefail
cd "$(dirname "$0")/.."
PLUGINS="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
if [ -d "$PLUGINS" ]; then
  swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
else
  swift test "$@"
fi
