#!/usr/bin/env bats
# How items resolve per platform, and how plans are built.

setup() {
  load helper
  load_sk
  catalog_load
  OS=linux FAMILY=debian PM=apt DISTRO_NAME=Test IS_IMMUTABLE=false IS_MUSL=false ARCH=amd64
  TARGET_USER=tester
  catalog_resolve
}

@test "the most specific target wins" {
  [ "$(item_spec mtr)" = pkg:mtr-tiny ]      # debian= beats mac=/others
  FAMILY=rhel; catalog_resolve
  [ "$(item_spec mtr)" = pkg:mtr ]
  OS=mac FAMILY=mac; catalog_resolve
  [ "$(item_spec mtr)" = brew:mtr ]
  [ "$(item_spec ripgrep)" = brew:ripgrep ]   # all=
}

@test "items not offered on a platform resolve to nothing" {
  OS=mac FAMILY=mac; catalog_resolve
  [ -z "$(item_spec k3s)" ]
  ! item_available k3s
}

@test "scope: native and system items need sudo, brew items don't" {
  [ "$(item_scope fail2ban)" = system ]
  [ "$(item_scope ripgrep)" = user ]
}

@test "a plan pulls in dependencies, in catalog order" {
  resolve_plan zsh-setup
  [ "${PLAN[*]}" = "homebrew starship zsh-setup" ]
}

@test "npm items bring mise; flatpak items bring flatpak" {
  resolve_plan gemini vscode
  [[ " ${PLAN[*]} " == *" runtimes "* ]]
  [[ " ${PLAN[*]} " == *" flatpak "* ]]
}

@test "without Homebrew (root), brew items and their dependents are skipped" {
  TARGET_USER=root; catalog_resolve
  resolve_plan ripgrep zsh-setup fail2ban
  [[ " ${PLAN[*]} " == *" fail2ban "* ]]
  [[ " ${PLAN_SKIPPED[*]} " == *" ripgrep "* ]]
  [[ " ${PLAN_SKIPPED[*]} " == *" zsh-setup "* ]]
}

@test "on an image-based OS, system items are skipped" {
  IS_IMMUTABLE=true; catalog_resolve
  resolve_plan fail2ban ripgrep
  [[ " ${PLAN_SKIPPED[*]} " == *" fail2ban "* ]]
  [[ " ${PLAN[*]} " == *" ripgrep "* ]]
}

@test "catalog JSON is valid and complete" {
  command -v jq >/dev/null || skip "jq not installed"
  catalog_json >"$BATS_TEST_TMPDIR/c.json"
  jq -e '.items | length > 100' "$BATS_TEST_TMPDIR/c.json"
  jq -e '[.items[] | select(.id == "docker")][0].scope == "system"' "$BATS_TEST_TMPDIR/c.json"
}

@test "sudo is requested for system items, a first Homebrew install, and casks" {
  brew_find() { return 0; }
  PLAN=(ripgrep jq)
  ! plan_needs_sudo
  PLAN=(ripgrep fail2ban)
  plan_needs_sudo
  brew_find() { return 1; }
  PLAN=(homebrew ripgrep)
  plan_needs_sudo
  brew_find() { return 0; }
  OS=mac FAMILY=mac; catalog_resolve
  PLAN=(rectangle)
  plan_needs_sudo
}

@test "pkg_install ignores empty names and does nothing when all are empty" {
  PM=apt
  apt-get() { echo "should not run" >&2; return 1; }
  run pkg_install "" ""
  [ "$status" -eq 0 ]
  [[ $output != *"should not run"* ]]
}

@test "a distro-specific target beats the family, and none: hides the item" {
  FAMILY=rhel DISTRO_ID=amzn DISTRO_NAME="Amazon Linux 2023"; catalog_resolve
  ! item_available mosh
  [[ $(item_unavailable_reason mosh) == "not packaged for Amazon Linux 2023" ]]
  DISTRO_ID=rocky; catalog_resolve
  item_available mosh
}
