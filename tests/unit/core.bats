#!/usr/bin/env bats

setup() {
  load helper
  load_sk
}

@test "json_str escapes quotes, backslashes, newlines and tabs" {
  [ "$(json_str $'a"b\\c\nd\te')" = '"a\"b\\c\nd\te"' ]
}

@test "quote_cmd shows arguments exactly" {
  [ "$(quote_cmd echo 'a b' "c'd" plain)" = "echo a\\ b c\\'d plain" ]
}

@test "run does nothing in a dry run" {
  DRY_RUN=true
  run run_cmd touch "$BATS_TEST_TMPDIR/x"
  [ ! -e "$BATS_TEST_TMPDIR/x" ]
  [[ $output == *"would run: touch"* ]]
}

@test "events are valid JSON lines" {
  command -v jq >/dev/null || skip "jq not installed"
  EVENTS_FILE="$BATS_TEST_TMPDIR/ev"
  event item_start id docker name 'Docker "Engine"'
  jq -e '.event == "item_start" and .name == "Docker \"Engine\""' "$EVENTS_FILE"
}

@test "hints are de-duplicated" {
  hint "do this"
  hint "do this"
  [ "$(wc -l <"$RUN_DIR/hints")" -eq 1 ]
}

@test "na returns 3 and records the reason" {
  CURRENT_ITEM=demo
  run na "not here"
  [ "$status" -eq 3 ]
  [ "$(cat "$RUN_DIR/.na-demo")" = "not here" ]
}
