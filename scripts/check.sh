#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Keep generated bundles out of cloud-synced Documents folders with inherited Finder metadata.
./scripts/version-tests.sh
swift test --scratch-path "${INTERVAL_SCRATCH:-${TMPDIR:-/tmp}/interval-spm-$UID}"
git diff --check
