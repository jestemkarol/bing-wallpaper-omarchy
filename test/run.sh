#!/bin/bash

# Runs every test suite. No network, no running shell.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

status=0

"$HERE/sync.sh" || status=1
echo
if command -v node >/dev/null; then
  node "$HERE/model.js" || status=1
else
  echo "Model.js: skipped (node is not installed)"
fi

echo
if (( status == 0 )); then
  echo "all suites passed"
else
  echo "some suites failed"
fi
exit "$status"
