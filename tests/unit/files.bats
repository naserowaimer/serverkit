#!/usr/bin/env bats
# safe_write / ensure_block / restore_file: the "never clobber your files" contract.

setup() {
  load helper
  load_sk
  F="$TARGET_HOME/conf"
}

@test "safe_write creates a missing file" {
  safe_write "$F" 0640 <<<"# $MARKER
hello"
  [ -f "$F" ]
  [ "$(sed -n 2p "$F")" = hello ]
  [ "$(file_mode "$F")" = 640 ]
  $SW_CHANGED
}

@test "safe_write leaves an identical file alone" {
  printf '# %s\nx\n' "$MARKER" >"$F"
  safe_write "$F" <<<"# $MARKER
x"
  ! $SW_CHANGED
  [ -z "$(ls "$TARGET_HOME" | grep bak)" ]
}

@test "safe_write never overwrites a file it didn't write" {
  echo "mine" >"$F"
  safe_write "$F" <<<"# $MARKER
ours"
  [ "$(cat "$F")" = mine ]
  grep -q ours "$F.new"
  ! $SW_CHANGED
}

@test "safe_write updates its own file and keeps a backup" {
  printf '# %s\nold\n' "$MARKER" >"$F"
  safe_write "$F" <<<"# $MARKER
new"
  grep -q new "$F"
  grep -q old "$F.bak.$STAMP"
  $SW_CHANGED
}

@test "--force adopts a foreign file, keeping a backup" {
  echo "mine" >"$F"
  FORCE=true
  safe_write "$F" <<<"# $MARKER
ours"
  grep -q ours "$F"
  grep -q mine "$F.bak.$STAMP"
}

@test "dry run writes nothing" {
  DRY_RUN=true
  run safe_write "$F" <<<"# $MARKER
x"
  [ "$status" -eq 0 ]
  [[ $output == *"would create"* ]]
  [ ! -e "$F" ]
}

@test "restore_file undoes an update" {
  printf '# %s\nold\n' "$MARKER" >"$F"
  safe_write "$F" <<<"# $MARKER
bad"
  restore_file "$F"
  grep -q old "$F"
}

@test "restore_file removes a file that was newly created" {
  safe_write "$F" <<<"# $MARKER
bad"
  restore_file "$F"
  [ ! -e "$F" ]
}

@test "ensure_block creates a file with just the block" {
  ensure_block "$F" demo <<<"line one"
  [ "$(cat "$F")" = "$(printf '# >>> serverkit:demo >>>\nline one\n# <<< serverkit:demo <<<')" ]
}

@test "ensure_block keeps everything outside the block" {
  printf 'mine 1\nmine 2\n' >"$F"
  ensure_block "$F" demo <<<"ours"
  ensure_block "$F" demo <<<"ours v2"
  [ "$(head -n 2 "$F")" = "$(printf 'mine 1\nmine 2')" ]
  grep -q 'ours v2' "$F"
  ! grep -qx 'ours' "$F"
  [ "$(grep -c 'serverkit:demo >>>' "$F")" -eq 1 ]
}

@test "ensure_block preserves backslashes and dollars" {
  ensure_block "$F" demo <<<'printf "\e[1m%s\n" "$HOME"'
  grep -qF 'printf "\e[1m%s\n" "$HOME"' "$F"
}

@test "ensure_block is idempotent" {
  ensure_block "$F" demo <<<"x"
  cp "$F" "$F.first"
  ensure_block "$F" demo <<<"x"
  cmp "$F" "$F.first"
}
