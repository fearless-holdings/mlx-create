#!/bin/bash
# Fetches, verifies, embeds and re-signs the pinned upstream mlx-serve engine.
# Implements docs/lld/engine.md §4. Upstream: ddalcu/mlx-serve @ ccedc6a (MIT).
#
# Modes:
#   (no args)           build phase, run by Xcode (needs TARGET_BUILD_DIR etc.)
#   --check             fetch into cache if needed, verify, report
#   --extract DIR       verify, then extract the payload into DIR/<root>
#   --refresh-manifest  after bumping engine.lock's url/version: fetch the URL,
#                       rewrite sha256, size and payload lists, print them.
# Env: MLXC_ENGINE_OFFLINE=1 turns a cache miss into an error.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$REPO/engine.lock"

fail() { echo "error: embed-engine: $*" >&2; exit 1; }

lock() { plutil -extract "$1" raw -o - "$LOCK" 2>/dev/null || fail "engine.lock has no key '$1'"; }
lock_list() {
  local i=0 v
  while v=$(plutil -extract "$1.$i" raw -o - "$LOCK" 2>/dev/null); do
    printf '%s\n' "$v"
    i=$((i + 1))
  done
}

[ "$(lock schema)" = "1" ] || fail "engine.lock schema $(lock schema) is unknown to this script (expected 1)"
VERSION=$(lock version)
URL=$(lock url)
SHA=$(lock sha256)
SIZE=$(lock size)
TEAM=$(lock upstream_team_id)
PKG_ROOT=$(lock root)
EXE=$(lock executable)
FRAMEWORKS=$(lock_list frameworks)
NOTICES=$(lock_list notices)

CACHE_DIR="$HOME/Library/Caches/mlx-create/engine"
CACHE="$CACHE_DIR/$SHA.tar.gz"
DESIRED_RPATHS=('@executable_path/../Frameworks' '@executable_path/../Resources/mlx')

# ---- 1. Fetch -------------------------------------------------------------

verify_archive() {
  [ -f "$1" ] || fail "engine archive missing: $1"
  local got
  got=$(shasum -a 256 "$1" | cut -d' ' -f1)
  [ "$got" = "$SHA" ] || fail "engine sha256 mismatch for $1: expected $SHA, found $got (delete the cache entry and rebuild)"
  got=$(stat -f%z "$1")
  [ "$got" = "$SIZE" ] || fail "engine size mismatch for $1: expected $SIZE bytes, found $got"
}

# Entry-level checks run before anything is extracted (LLD §4.2.2).
verify_entries() {
  local bad
  bad=$(tar -tvzf "$1" | awk '{ t = substr($1, 1, 1); if (t != "-" && t != "d") { print; exit } }')
  [ -z "$bad" ] || fail "engine archive has a link or device entry: $bad"
  bad=$(tar -tzf "$1" | grep -m1 -E '^/|(^|/)\.\.(/|$)' || true)
  [ -z "$bad" ] || fail "engine archive entry escapes its root: $bad"
}

fetch_archive() {
  if [ -f "$CACHE" ]; then return 0; fi
  [ "${MLXC_ENGINE_OFFLINE:-0}" != 1 ] || fail "engine $VERSION is not cached at $CACHE and MLXC_ENGINE_OFFLINE=1"
  mkdir -p "$CACHE_DIR"
  trap 'rm -f "$CACHE.part"' EXIT
  curl -fL --retry 3 --proto '=https' -o "$CACHE.part" "$URL" || fail "download failed: $URL"
  verify_archive "$CACHE.part"
  verify_entries "$CACHE.part"
  mv "$CACHE.part" "$CACHE"
  trap - EXIT
}

ensure_verified_archive() {
  fetch_archive
  verify_archive "$CACHE"
  verify_entries "$CACHE"
}

# ---- 2. Verify (payload) --------------------------------------------------

# Expected payload, one path per line, relative to the tarball root.
expected_payload() {
  {
    printf '%s\n' "$EXE"
    printf '%s\n' "$FRAMEWORKS"
    printf '%s\n' "$NOTICES"
  } | awk 'NF' | sort
}

# Files that get codesign checks: the binary and every dylib.
macho_list() {
  printf '%s\n' "$EXE"
  printf '%s\n' "$FRAMEWORKS" | awk '/\.dylib$/'
}

check_payload_list() {
  # $1 = file with actual relative paths, sorted
  local expected actual unexpected missing
  expected=$(mktemp); actual=$(mktemp)
  expected_payload > "$expected"
  sort "$1" > "$actual"
  unexpected=$(comm -13 "$expected" "$actual" | tr '\n' ' ')
  missing=$(comm -23 "$expected" "$actual" | tr '\n' ' ')
  rm -f "$expected" "$actual"
  [ -z "$unexpected" ] || fail "engine payload has files not listed in engine.lock: ${unexpected% }"
  [ -z "$missing" ] || fail "engine payload is missing files listed in engine.lock: ${missing% }"
}

verify_tarball_payload() {
  local listing
  listing=$(mktemp)
  tar -tzf "$1" | awk '!/\/$/' | while IFS= read -r p; do
    [ "${p%%/*}" = "$PKG_ROOT" ] || fail "engine archive has an entry outside '$PKG_ROOT/': $p"
    printf '%s\n' "${p#"$PKG_ROOT"/}"
  done > "$listing"
  check_payload_list "$listing"
  rm -f "$listing"
}

extract_to() {  # $1 archive, $2 parent dir
  rm -rf "$2/$PKG_ROOT"
  mkdir -p "$2"
  tar -xzf "$1" -C "$2" --no-same-owner --no-same-permissions
  chmod 755 "$2/$PKG_ROOT/$EXE"
  chmod -R u+w "$2/$PKG_ROOT"
}

verify_extracted() {  # $1 = payload root (extracted)
  local listing
  listing=$(mktemp)
  (cd "$1" && find . -type f | sed 's|^\./||' | sort) > "$listing"
  check_payload_list "$listing"
  rm -f "$listing"
  local p
  while IFS= read -r p; do
    codesign --verify --strict "$1/$p" 2>/dev/null || fail "upstream signature does not verify: $p"
    local team
    team=$(codesign -dv --verbose=4 "$1/$p" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    [ "$team" = "$TEAM" ] || fail "upstream Team ID for $p: expected $TEAM, found ${team:-none}"
  done <<< "$(macho_list)"
}

# ---- Linkage helpers ------------------------------------------------------

# $1 file, $2 first line to read from otool -L (2 for binaries; 3 for dylibs, skipping the ID)
dep_list() { otool -L "$1" | tail -n +"$2" | awk '{print $1}'; }
rpath_list() { otool -l "$1" | awk '$1 == "cmd" && $2 == "LC_RPATH" { f = 1; next } f && $1 == "path" { print $2; f = 0 }'; }

# ---- Refresh (bump helper) ------------------------------------------------

refresh_manifest() {
  local new_sha new_size rel frameworks notices
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl -fL --retry 3 --proto '=https' -o "$tmp/engine.tar.gz" "$URL" || fail "download failed: $URL"
  new_sha=$(shasum -a 256 "$tmp/engine.tar.gz" | cut -d' ' -f1)
  new_size=$(stat -f%z "$tmp/engine.tar.gz")
  verify_entries "$tmp/engine.tar.gz"
  rel=$(tar -tzf "$tmp/engine.tar.gz" | awk '!/\/$/' | sed "s|^$PKG_ROOT/||")
  [ -n "$rel" ] || fail "engine archive is empty"
  printf '%s\n' "$rel" | grep -qxF "$EXE" || fail "engine archive has no '$EXE' under '$PKG_ROOT/'"
  frameworks=$(printf '%s\n' "$rel" | awk '/^lib\//')
  notices=$(printf '%s\n' "$rel" | awk '!/^lib\// && $0 != "'"$EXE"'"')
  extract_to "$tmp/engine.tar.gz" "$tmp/x"
  local first
  first=$(env -i PATH=/usr/bin:/bin HOME="$tmp" "$tmp/x/$PKG_ROOT/$EXE" --version 2>&1 | awk '/^mlx-serve /{print; exit}') || true
  [ "$first" = "mlx-serve $VERSION" ] || fail "engine.lock version is '$VERSION' but the archive reports '${first:-nothing}'; set version and tag first"

  mkdir -p "$CACHE_DIR"
  mv "$tmp/engine.tar.gz" "$CACHE_DIR/$new_sha.tar.gz"

  json_array() {
    local out="" s sep=""
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      out="$out$sep\"$s\""
      sep=","
    done
    printf '[%s]' "$out"
  }
  plutil -replace sha256 -string "$new_sha" "$LOCK"
  plutil -replace size -integer "$new_size" "$LOCK"
  plutil -replace frameworks -json "$(printf '%s\n' "$frameworks" | json_array)" "$LOCK"
  plutil -replace notices -json "$(printf '%s\n' "$notices" | json_array)" "$LOCK"
  echo "engine.lock updated: sha256=$new_sha size=$new_size"
  echo "frameworks:"; printf '  %s\n' $frameworks
  echo "notices:"; printf '  %s\n' $notices
  echo "Review the lists, then run: scripts/embed-engine.sh --check"
}

# ---- Modes ----------------------------------------------------------------

case "${1:-}" in
  --refresh-manifest)
    refresh_manifest
    exit 0
    ;;
  --check)
    ensure_verified_archive
    verify_tarball_payload "$CACHE"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    extract_to "$CACHE" "$tmp"
    verify_extracted "$tmp/$PKG_ROOT"
    echo "engine $VERSION verified: $CACHE"
    exit 0
    ;;
  --extract)
    [ -n "${2:-}" ] || fail "--extract needs a destination directory"
    ensure_verified_archive
    verify_tarball_payload "$CACHE"
    extract_to "$CACHE" "$2"
    verify_extracted "$2/$PKG_ROOT"
    echo "$2/$PKG_ROOT"
    exit 0
    ;;
  "")
    ;;
  *)
    fail "unknown argument '$1' (use --check, --extract DIR or --refresh-manifest)"
    ;;
esac

# ---- Build phase ----------------------------------------------------------

: "${TARGET_BUILD_DIR:?embed-engine: TARGET_BUILD_DIR is not set; run from Xcode or use --check/--extract}"
: "${CONTENTS_FOLDER_PATH:?embed-engine: CONTENTS_FOLDER_PATH is not set}"
: "${PRODUCT_BUNDLE_IDENTIFIER:?embed-engine: PRODUCT_BUNDLE_IDENTIFIER is not set}"
SIGN_ID="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ]; then
  [ "${CONFIGURATION:-}" != Release ] || fail "EXPANDED_CODE_SIGN_IDENTITY is empty; a Release build needs a Developer ID identity"
  SIGN_ID=-
fi

ensure_verified_archive
verify_tarball_payload "$CACHE"

WORK="${DERIVED_FILE_DIR:-${TMPDIR:-/tmp}}/engine/$SHA"
rm -rf "$WORK"
extract_to "$CACHE" "$WORK"
PAYLOAD="$WORK/$PKG_ROOT"
verify_extracted "$PAYLOAD"

CONTENTS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
MACOS="$CONTENTS/MacOS"
FW="$CONTENTS/Frameworks"
TP="$CONTENTS/Resources/ThirdParty/mlx-serve"
BIN="$MACOS/$EXE"

# 3. Embed. MLX only searches the directory of libmlx.dylib for mlx.metallib, and codesign
# rejects a non-Mach-O file in Frameworks/, so libmlx.dylib and mlx.metallib live in Resources/mlx.
MLXDIR="$CONTENTS/Resources/mlx"
is_mlx() { case "$1" in libmlx.dylib|mlx.metallib) return 0 ;; *) return 1 ;; esac; }
rm -rf "$MLXDIR"
rm -f "$BIN" "$FW"/*.dylib "$TP"/*
while IFS= read -r p; do rm -f "$FW/${p##*/}"; done <<< "$FRAMEWORKS"
mkdir -p "$MACOS" "$FW" "$TP" "$MLXDIR" "$CONTENTS/Resources"
ditto --noqtn "$PAYLOAD/$EXE" "$BIN"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  n="${p##*/}"
  if is_mlx "$n"; then ditto --noqtn "$PAYLOAD/$p" "$MLXDIR/$n"; else ditto --noqtn "$PAYLOAD/$p" "$FW/$n"; fi
done <<< "$FRAMEWORKS"
while IFS= read -r n; do
  [ -n "$n" ] || continue
  ditto --noqtn "$PAYLOAD/$n" "$TP/$n"
done <<< "$NOTICES"
chmod 755 "$BIN"
chmod u+w "$FW"/* "$MLXDIR"/* "$TP"/*

# 4. Install-name fixes, rule-driven (LLD §4.4).
while IFS= read -r dep; do
  case "$dep" in
    @executable_path/lib/*)
      n="${dep##*/}"
      if is_mlx "$n"; then t="@executable_path/../Resources/mlx/$n"; else t="@executable_path/../Frameworks/$n"; fi
      install_name_tool -change "$dep" "$t" "$BIN" ;;
  esac
done <<< "$(dep_list "$BIN" 2)"

rpath_out=$(rpath_list "$BIN")
while IFS= read -r rp; do
  [ -n "$rp" ] || continue
  keep=0
  for want in "${DESIRED_RPATHS[@]}"; do [ "$rp" = "$want" ] && keep=1; done
  [ "$keep" = 1 ] || install_name_tool -delete_rpath "$rp" "$BIN"
done <<< "$rpath_out"
for want in "${DESIRED_RPATHS[@]}"; do
  grep -qxF "$want" <<< "$(rpath_list "$BIN")" || install_name_tool -add_rpath "$want" "$BIN"
done

# Dylibs in Frameworks/ load libmlx from Resources/mlx; dylibs in Resources/mlx load siblings.
for f in "$MLXDIR"/*.dylib "$FW"/*.dylib; do
  [ -f "$f" ] || continue
  case "$(otool -D "$f" | tail -n +2)" in
    /*) install_name_tool -id "@rpath/${f##*/}" "$f" ;;
  esac
  in_mlx=0; case "$f" in "$MLXDIR"/*) in_mlx=1 ;; esac
  while IFS= read -r dep; do
    case "$dep" in
      /usr/lib/*|/System/*|"") ;;
      *)
        n="${dep##*/}"
        if is_mlx "$n"; then
          if [ "$in_mlx" = 1 ]; then t="@loader_path/$n"; else t="@loader_path/../Resources/mlx/$n"; fi
        elif [ -f "$FW/$n" ]; then
          if [ "$in_mlx" = 1 ]; then t="@loader_path/../../Frameworks/$n"; else t="@loader_path/$n"; fi
        else
          continue
        fi
        install_name_tool -change "$dep" "$t" "$f" ;;
    esac
  done <<< "$(dep_list "$f" 3)"
done

# 5. Re-sign inside-out (LLD §4.5). Release adds a secure timestamp; Debug works offline.
SIGN_TS=()
[ "${CONFIGURATION:-}" != Release ] || SIGN_TS=(--timestamp)
# Ad-hoc signing has no Team ID, so hardened library validation rejects the embedded dylibs
# ("different Team IDs", observed on the Debug build). Xcode disables hardened runtime for ad-hoc too.
RUNTIME=(--options runtime)
[ "$SIGN_ID" != - ] || RUNTIME=()
for f in "$MLXDIR"/*.dylib "$FW"/*.dylib; do
  [ -f "$f" ] || continue
  codesign --force ${RUNTIME[@]+"${RUNTIME[@]}"} ${SIGN_TS[@]+"${SIGN_TS[@]}"} --sign "$SIGN_ID" "$f"
done
codesign --force ${RUNTIME[@]+"${RUNTIME[@]}"} ${SIGN_TS[@]+"${SIGN_TS[@]}"} --sign "$SIGN_ID" \
  --identifier "$PRODUCT_BUNDLE_IDENTIFIER.engine" --entitlements "$REPO/Config/Engine.entitlements" "$BIN"

# 6. Post-checks (LLD §4.6).
check_linkage() {  # $1 file, $2 first dependency line
  local f="$1" dep n
  while IFS= read -r dep; do
    case "$dep" in
      /usr/lib/*|/System/*|"") ;;
      /*) fail "unresolved absolute load in ${f#"$CONTENTS/"}: $dep" ;;
      @rpath/*|@loader_path/*|@executable_path/*)
        n="${dep##*/}"
        [ -f "$FW/$n" ] || [ -f "$MLXDIR/$n" ] || fail "load $dep in ${f#"$CONTENTS/"} has no file in Frameworks/ or Resources/mlx/" ;;
      *) fail "unexpected load in ${f#"$CONTENTS/"}: $dep" ;;
    esac
  done <<< "$(dep_list "$f" "$2")"
}
codesign --verify --strict "$BIN" 2>/dev/null || fail "signature does not verify: ${BIN#"$CONTENTS/"}"
check_linkage "$BIN" 2
for f in "$MLXDIR"/*.dylib "$FW"/*.dylib; do
  [ -f "$f" ] || continue
  codesign --verify --strict "$f" 2>/dev/null || fail "signature does not verify: ${f#"$CONTENTS/"}"
  check_linkage "$f" 3
done
version_out=$(env -i PATH=/usr/bin:/bin HOME="$WORK/home" "$BIN" --version 2>&1) || fail "engine --version failed to run"
first=$(printf '%s\n' "$version_out" | awk '/^mlx-serve /{print; exit}')
[ "$first" = "mlx-serve $VERSION" ] || fail "embedded engine reports '${first:-nothing}', expected 'mlx-serve $VERSION'"

echo "embed-engine: embedded mlx-serve $VERSION into $CONTENTS"
