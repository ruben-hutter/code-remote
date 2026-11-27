#!/usr/bin/env bash
# Integration regression for legacy nix-env profiles containing clang and
# binutils at the same priority. Uses tiny synthetic store paths and a
# disposable profile; the user's real profile is never touched.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

export NIX_CONFIG="experimental-features = nix-command flakes"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

make_store_package() {
  local name="$1" marker="$2" with_as="$3"
  local src="$TEST_TMP/src-$name"
  mkdir -p "$src/bin"
  printf '#!/bin/sh\nexit 0\n' >"$src/bin/$marker"
  chmod +x "$src/bin/$marker"
  if [ "$with_as" = 1 ]; then
    ln -s "$marker" "$src/bin/as"
  fi
  nix store add-path --name "$name" "$src"
}

CLANG_PATH="$(make_store_package clang-wrapper-1 clang-test 1)"
BINUTILS_PATH="$(make_store_package binutils-wrapper-1 binutils-test 1)"
NEUTRAL_PATH="$(make_store_package neutral-1 neutral-test 0)"

# New Nix versions reject the collision while a profile is being built. Seed
# a valid temporary profile at distinct priorities first, then clone it into a
# writable legacy-style generation and make the priorities equal. This models
# the real nix-env -> nix profile manifest that triggered the bootstrap bug.
PROFILE="$TEST_TMP/profile"
nix profile add --profile "$PROFILE" --priority 10 "$CLANG_PATH"
nix profile add --profile "$PROFILE" --priority 11 "$BINUTILS_PATH"

GENERATION_NAME="$(readlink "$PROFILE")"
GENERATION_STORE="$(readlink -f "$PROFILE")"
REPAIR_DIR="$TEST_TMP/repair"
mkdir "$REPAIR_DIR" "$REPAIR_DIR/generation"
cp -a "$GENERATION_STORE"/. "$REPAIR_DIR/generation"/
chmod -R u+w "$REPAIR_DIR/generation"
sed -i 's/"priority"[[:space:]]*:[[:space:]]*11/"priority": 10/' \
  "$REPAIR_DIR/generation/manifest.json"
ln -s "$REPAIR_DIR/generation" "$REPAIR_DIR/$GENERATION_NAME"
ln -s "$GENERATION_NAME" "$REPAIR_DIR/profile"
PROFILE="$REPAIR_DIR/profile"

set +e
CONFLICT_OUTPUT="$(nix profile add --profile "$PROFILE" "$NEUTRAL_PATH" 2>&1)"
CONFLICT_STATUS=$?
set -e
[ "$CONFLICT_STATUS" -ne 0 ] || fail 'test setup did not reproduce a profile failure'
grep -Eq 'There is a conflict for the following files|An existing package already provides the following file' <<<"$CONFLICT_OUTPUT" \
  || fail "unexpected failure: $CONFLICT_OUTPUT"
grep -F -q "$CLANG_PATH/bin/as" <<<"$CONFLICT_OUTPUT" \
  || fail 'clang bin/as collision was not reproduced'
grep -F -q "$BINUTILS_PATH/bin/as" <<<"$CONFLICT_OUTPUT" \
  || fail 'binutils bin/as collision was not reproduced'
printf 'reproduced: same-priority clang/binutils bin/as conflict\n'

# shellcheck source=/dev/null
source "$REPO_ROOT/remote/bootstrap.sh"
trap 'rm -rf "$TEST_TMP" "$TMP"' EXIT

# This is red until the bootstrap provides the preservation repair.
if ! declare -F repair_clang_binutils_profile_collision >/dev/null; then
  fail 'bootstrap has no clang/binutils profile collision repair'
fi

repair_clang_binutils_profile_collision "$PROFILE"
nix profile add --profile "$PROFILE" "$NEUTRAL_PATH"
repair_clang_binutils_profile_collision "$PROFILE" # second run must be a no-op

[ -x "$PROFILE/bin/clang-test" ] || fail 'clang output was not preserved'
[ -x "$PROFILE/bin/binutils-test" ] || fail 'binutils output was not preserved'
[ -x "$PROFILE/bin/neutral-test" ] || fail 'subsequent profile install still fails'
[ "$(readlink "$PROFILE/bin/as")" = "$BINUTILS_PATH/bin/as" ] \
  || fail 'assembler precedence is not deterministic'

printf 'PASS: conflict repaired, packages preserved, later activation succeeds\n'
