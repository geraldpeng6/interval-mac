#!/bin/bash
# Boundary tests for release version metadata handling.
# Runs the real scripts/version.sh CLI against an isolated temp plist; no app
# build, no repo file mutation, no GUI.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION_SH=scripts/version.sh
PLIST_BUDDY=/usr/libexec/PlistBuddy
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/interval-version-tests.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT

pass=0
fail=0

expect_ok() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $label" >&2
  fi
}

expect_fail() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    fail=$((fail + 1))
    echo "FAIL (expected nonzero exit): $label" >&2
  else
    pass=$((pass + 1))
  fi
}

expect_output() {
  local label="$1" expected="$2"; shift 2
  local actual
  if actual="$("$@" 2>/dev/null)" && [[ "$actual" == "$expected" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $label (got '${actual:-<none>}', want '$expected')" >&2
  fi
}

# --- Strict semver validation -------------------------------------------------
expect_ok "accept stable semver" "$VERSION_SH" validate 1.0.0
expect_ok "accept prerelease semver" "$VERSION_SH" validate 1.0.0-rc.2
expect_ok "accept prerelease with build metadata" "$VERSION_SH" validate 1.0.0-rc.2+build.7
expect_fail "reject two-component version" "$VERSION_SH" validate 1.0
expect_fail "reject v-prefixed version" "$VERSION_SH" validate v1.0.0
expect_fail "reject leading zero component" "$VERSION_SH" validate 01.0.0
expect_fail "reject empty prerelease" "$VERSION_SH" validate 1.0.0-
expect_fail "reject prerelease numeric identifier with leading zero" "$VERSION_SH" validate 1.0.0-rc.01
expect_fail "reject empty prerelease identifier" "$VERSION_SH" validate 1.0.0-rc..2
expect_fail "reject nonnumeric component" "$VERSION_SH" validate 1.x.0
expect_fail "reject missing version argument" "$VERSION_SH" validate

# --- Apple numeric version boundaries ----------------------------------------
expect_ok "accept component at Apple limit" "$VERSION_SH" validate 1.0.65535
expect_ok "accept 5-digit component under limit" "$VERSION_SH" validate 1.0.9999
expect_fail "reject component over Apple limit" "$VERSION_SH" validate 1.0.65536
expect_fail "reject 5-digit component over Apple limit" "$VERSION_SH" validate 1.0.99999
# 20-digit components wrap mod 2^64 in bash arithmetic; without a length
# guard they pass the <= 65535 check and reach the bundle metadata.
expect_fail "reject 20-digit component wrapping to 1" "$VERSION_SH" validate 1.0.18446744073709551617
expect_fail "reject 20-digit component wrapping to 0" "$VERSION_SH" validate 1.0.18446744073709551616
expect_output "apple version strips prerelease" "1.0.0" "$VERSION_SH" apple-version 1.0.0-rc.2
expect_output "apple version keeps patch" "1.2.3" "$VERSION_SH" apple-version 1.2.3
expect_fail "reject apple-version of invalid semver" "$VERSION_SH" apple-version 1.0

# --- Release channel ----------------------------------------------------------
expect_output "prerelease channel detected" "prerelease" "$VERSION_SH" channel 1.0.0-rc.2
expect_output "stable channel detected" "stable" "$VERSION_SH" channel 1.0.0
expect_fail "channel of invalid semver fails" "$VERSION_SH" channel not.a.version

# --- Tag validation against committed VERSION / BUILD_NUMBER ------------------
# Expectations are derived from the committed VERSION so the suite stays
# valid after the next bump without editing these tests (docs/RELEASING.md
# bump-then-tag procedure).
COMMITTED_VERSION="$(cat VERSION)"
expect_ok "accept tag matching committed version" "$VERSION_SH" check-tag "v${COMMITTED_VERSION}"
# Guaranteed mismatch: appending a prerelease identifier keeps strict semver
# but can never equal the committed VERSION string, whatever it is.
expect_fail "reject semver tag mismatching committed version" "$VERSION_SH" check-tag "v${COMMITTED_VERSION}-0"
expect_fail "reject tag without v prefix" "$VERSION_SH" check-tag "${COMMITTED_VERSION}"
expect_fail "reject tag that is not semver" "$VERSION_SH" check-tag v1.0

# --- Bundle metadata application on an isolated fixture -----------------------
PLIST="$FIXTURE/Info.plist"
cp Resources/Info.plist "$PLIST"

expect_ok "apply rc1 metadata" "$VERSION_SH" set-metadata "$PLIST" 1.0.0-rc.1 1
expect_output "rc1 short version is numeric" "1.0.0" \
  "$PLIST_BUDDY" -c "Print :CFBundleShortVersionString" "$PLIST"
expect_output "rc1 build is 1" "1" "$PLIST_BUDDY" -c "Print :CFBundleVersion" "$PLIST"
expect_output "rc1 full version retained" "1.0.0-rc.1" \
  "$PLIST_BUDDY" -c "Print :IntervalFullVersion" "$PLIST"

# A new rc must not ship carrying the previous rc's metadata.
expect_ok "apply rc2 metadata over rc1 metadata" "$VERSION_SH" set-metadata "$PLIST" 1.0.0-rc.2 2
expect_output "rc2 short version stays numeric" "1.0.0" \
  "$PLIST_BUDDY" -c "Print :CFBundleShortVersionString" "$PLIST"
expect_output "rc2 build bumps to 2" "2" "$PLIST_BUDDY" -c "Print :CFBundleVersion" "$PLIST"
expect_output "rc2 full version replaces rc1" "1.0.0-rc.2" \
  "$PLIST_BUDDY" -c "Print :IntervalFullVersion" "$PLIST"
expect_output "unrelated plist keys survive" "14.0" \
  "$PLIST_BUDDY" -c "Print :LSMinimumSystemVersion" "$PLIST"

# --- Metadata input rejections must not touch the plist ------------------------
expect_fail "reject build 0" "$VERSION_SH" set-metadata "$PLIST" 1.0.0-rc.2 0
expect_fail "reject noninteger build" "$VERSION_SH" set-metadata "$PLIST" 1.0.0-rc.2 1.5
expect_fail "reject zero-padded build" "$VERSION_SH" set-metadata "$PLIST" 1.0.0-rc.2 007
expect_fail "reject oversized build" "$VERSION_SH" set-metadata "$PLIST" 1.0.0-rc.2 65536
expect_fail "reject 20-digit build wrapping below limit" "$VERSION_SH" set-metadata "$PLIST" 1.0.0-rc.2 18446744073709551617
expect_fail "reject invalid metadata version" "$VERSION_SH" set-metadata "$PLIST" 1.0 2
expect_fail "reject oversized apple component" "$VERSION_SH" set-metadata "$PLIST" 1.0.65536 2
expect_output "build unchanged after rejected inputs" "2" \
  "$PLIST_BUDDY" -c "Print :CFBundleVersion" "$PLIST"

printf 'version metadata tests: %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
