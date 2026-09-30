# shellcheck shell=bash
# Loads serverkit's libraries into a bats test with a throwaway home.
load_sk() {
  SK_ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  SK_VERSION=test
  export NO_COLOR=1
  for f in core platform pkg brew ui catalog main; do . "$SK_ROOT/lib/$f.sh"; done
  for f in "$SK_ROOT"/modules/*.sh; do . "$f"; done
  TARGET_USER=$(id -un)
  TARGET_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$TARGET_HOME"
  STATE_DIR="$TARGET_HOME/.local/state/serverkit"
  CONFIG_DIR="$TARGET_HOME/.config/serverkit"
  RUN_DIR="$BATS_TEST_TMPDIR/run"
  mkdir -p "$RUN_DIR"
  OPT_SET=()
  TMPDIR=$BATS_TEST_TMPDIR sk_tmp_init
}
