#!/bin/bash
# Version metadata helpers for Interval.
#
# Single source of release version metadata:
#   VERSION      full semver release version (e.g. 1.0.0-rc.2)
#   BUILD_NUMBER monotonic numeric Apple CFBundleVersion (e.g. 2)
#
# Apple bundle rules enforced here:
#   CFBundleShortVersionString must be three period-separated numeric
#   components (each <= 65535); Apple does not accept a prerelease suffix,
#   so the full release version is retained in the custom key
#   IntervalFullVersion for display and future updater comparisons.
#
# No nondeterministic identifiers: versions come only from committed files
# and tags, never from git commit counts or timestamps.
#
# CLI (also sourceable; functions are used by scripts/package.sh):
#   version.sh validate <version>        strict semver check (exit status)
#   version.sh apple-version <version>   print the numeric Apple version
#   version.sh channel <version>         print "prerelease" or "stable"
#   version.sh check-tag <tag>           v-tag must match committed VERSION/BUILD_NUMBER
#   version.sh set-metadata <plist> <version> <build>
#                                        apply all bundle version keys
set -euo pipefail

INTERVAL_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

readonly INTERVAL_SEMVER_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?(\+([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?$'
readonly INTERVAL_MAX_COMPONENT=65535

version_validate() {
  local version="${1:-}"
  if [[ ! "$version" =~ $INTERVAL_SEMVER_RE ]]; then
    echo "version.sh: '$version' is not strict semver (MAJOR.MINOR.PATCH[-PRERELEASE][+BUILD])" >&2
    return 1
  fi
  local minor_patch="${version#*.}"
  local patch_full="${minor_patch#*.}"
  local component
  for component in "${version%%.*}" "${minor_patch%%.*}" "${patch_full%%[-+]*}"; do
    # Bash arithmetic wraps mod 2^64; bound checks on longer strings are
    # unsound (a 20-digit component can wrap below the limit). 65535 is 5
    # digits, so any longer string already exceeds Apple's limit.
    if (( ${#component} > 5 )) || (( 10#$component > INTERVAL_MAX_COMPONENT )); then
      echo "version.sh: component '$component' of '$version' exceeds Apple's $INTERVAL_MAX_COMPONENT limit" >&2
      return 1
    fi
  done
}

version_build_validate() {
  local build="${1:-}"
  if [[ ! "$build" =~ ^(0|[1-9][0-9]*)$ ]]; then
    echo "version.sh: build number '$build' is not a plain non-negative integer" >&2
    return 1
  fi
  if (( 10#$build < 1 )); then
    echo "version.sh: build number '$build' must be >= 1 to keep CFBundleVersion monotonic" >&2
    return 1
  fi
  # Same wrap hazard as component checks: length guard before arithmetic.
  if (( ${#build} > 5 )) || (( 10#$build > INTERVAL_MAX_COMPONENT )); then
    echo "version.sh: build number '$build' exceeds Apple's $INTERVAL_MAX_COMPONENT limit" >&2
    return 1
  fi
}

version_apple_version() {
  local version="${1:-}"
  version_validate "$version"
  local minor_patch="${version#*.}"
  local patch_full="${minor_patch#*.}"
  printf '%s.%s.%s\n' "${version%%.*}" "${minor_patch%%.*}" "${patch_full%%[-+]*}"
}

version_channel() {
  local version="${1:-}"
  version_validate "$version"
  local without_build="${version%%+*}"
  if [[ "$without_build" == *-* ]]; then
    echo prerelease
  else
    echo stable
  fi
}

version_read_field() {
  local file="$1"
  local value=''
  read -r value < "$INTERVAL_REPO_ROOT/$file" || true
  printf '%s' "$value"
}

version_check_tag() {
  local tag="${1:-}"
  if [[ "$tag" != v* ]]; then
    echo "version.sh: release tag '$tag' must start with 'v'" >&2
    return 1
  fi
  local version="${tag#v}"
  version_validate "$version" || return 1
  local committed_version committed_build
  committed_version="$(version_read_field VERSION)"
  committed_build="$(version_read_field BUILD_NUMBER)"
  if [[ "$version" != "$committed_version" ]]; then
    echo "version.sh: tag $tag does not match committed VERSION '$committed_version'" >&2
    return 1
  fi
  if ! version_build_validate "$committed_build"; then
    echo "version.sh: committed BUILD_NUMBER '$committed_build' is not a usable monotonic build number" >&2
    return 1
  fi
  printf 'release %s ok: apple version %s, build %s\n' \
    "$tag" "$(version_apple_version "$version")" "$committed_build"
}

version_set_metadata() {
  local plist="$1" version="$2" build="$3"
  version_validate "$version" || return 1
  version_build_validate "$build" || return 1
  local apple
  apple="$(version_apple_version "$version")"
  local pair key value
  for pair in "CFBundleShortVersionString:$apple" "CFBundleVersion:$build" "IntervalFullVersion:$version"; do
    key="${pair%%:*}"
    value="${pair#*:}"
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist" 2>/dev/null ||
      /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist"
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    validate)
      version_validate "${2:-}"
      ;;
    apple-version)
      version_apple_version "${2:-}"
      ;;
    channel)
      version_channel "${2:-}"
      ;;
    check-tag)
      version_check_tag "${2:-}"
      ;;
    set-metadata)
      version_set_metadata "${2:-}" "${3:-}" "${4:-}"
      ;;
    *)
      grep '^#   version.sh' "$0" >&2
      exit 2
      ;;
  esac
fi
