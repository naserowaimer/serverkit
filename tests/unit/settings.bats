#!/usr/bin/env bats
# Settings files are parsed, never executed.

setup() {
  load helper
  load_sk
}

@test "defaults load and every profile parses" {
  settings_load
  [ "$SSH_PASSWORD_AUTH" = keep ]
  for p in personal apps desktop minimal; do
    settings_load "$p"
    [ -n "$ITEMS" ]
    [ -n "$PROFILE_DESC" ]
  done
}

@test "profile values override defaults; multi-line values join" {
  settings_load apps
  [ "$SSH_MAX_AUTH_TRIES" = 3 ]
  [[ $ITEMS == "essentials homebrew "* ]]
  [[ $ITEMS != *$'\n'* ]]
  [ "${SETTING_SRC[SSH_MAX_AUTH_TRIES]}" = profile:apps ]
}

@test "config file overrides the profile, --set overrides both" {
  mkdir -p "$CONFIG_DIR"
  echo 'SSH_MAX_AUTH_TRIES=7' >"$CONFIG_DIR/config.conf"
  settings_load apps
  [ "$SSH_MAX_AUTH_TRIES" = 7 ]
  OPT_SET=(SSH_MAX_AUTH_TRIES=9)
  settings_load apps
  [ "$SSH_MAX_AUTH_TRIES" = 9 ]
}

@test "a setting value is never executed" {
  mkdir -p "$CONFIG_DIR"
  printf 'DOMAIN=$(touch %s/pwned)\nDOCKER_ADDRESS_POOL=`touch %s/pwned2`\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" >"$CONFIG_DIR/config.conf"
  settings_load
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned2" ]
  [ "$DOMAIN" = "\$(touch $BATS_TEST_TMPDIR/pwned)" ]
}

@test "unknown settings are ignored with a warning" {
  mkdir -p "$CONFIG_DIR"
  echo 'SSH_PASWORD_AUTH=no' >"$CONFIG_DIR/config.conf"
  run settings_load
  [[ $output == *"unknown setting SSH_PASWORD_AUTH"* ]]
}

@test "config_set writes a value that reads back identically" {
  settings_load
  config_set DOMAIN "example.org"
  settings_load
  [ "$DOMAIN" = example.org ]
  config_set DOMAIN "example.net"
  [ "$(grep -c '^DOMAIN=' "$CONFIG_DIR/config.conf")" -eq 1 ]
}

@test "--set rejects unknown names" {
  OPT_SET=(NOPE=1)
  run settings_load
  [ "$status" -ne 0 ]
}
