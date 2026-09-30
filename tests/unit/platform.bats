#!/usr/bin/env bats
# Distro detection from os-release, derivatives included.

setup() {
  load helper
  load_sk
  # pretend every package manager exists; detection must pick by os-release
  have() { case "$1" in apt-get | dnf | pacman | zypper) return 0 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
}

detect() {
  SK_OS_RELEASE="$BATS_TEST_DIRNAME/fixtures/os-release/$1" detect_platform
}

@test "ubuntu -> debian/apt" { detect ubuntu-24.04; [ "$FAMILY" = debian ]; [ "$PM" = apt ]; [ "$CODENAME" = noble ]; }
@test "linux mint -> debian family, ubuntu base" { detect mint-22; [ "$FAMILY" = debian ]; [ "$(debian_base)" = "ubuntu noble" ]; }
@test "pop!_os -> ubuntu jammy base" { detect pop-22.04; [ "$(debian_base)" = "ubuntu jammy" ]; }
@test "debian -> debian bookworm" { detect debian-12; [ "$FAMILY" = debian ]; [ "$(debian_base)" = "debian bookworm" ]; }
@test "rocky -> rhel/dnf, major 9" { detect rocky-9; [ "$FAMILY" = rhel ]; [ "$PM" = dnf ]; [ "$VERSION_MAJOR" = 9 ]; }
@test "amazon linux -> rhel family" { detect amzn-2023; [ "$FAMILY" = rhel ]; [ "$DISTRO_ID" = amzn ]; }
@test "manjaro -> arch/pacman" { detect manjaro; [ "$FAMILY" = arch ]; [ "$PM" = pacman ]; }
@test "endeavouros -> arch via ID" { detect endeavouros; [ "$FAMILY" = arch ]; }
@test "openSUSE Leap -> suse/zypper" { detect opensuse-leap-15.6; [ "$FAMILY" = suse ]; [ "$PM" = zypper ]; }
@test "alpine -> unknown (no system items)" { detect alpine; [ "$FAMILY" = unknown ]; ! system_supported; }
@test "nixos -> unknown" { detect nixos; [ "$FAMILY" = unknown ]; }
@test "os-release variables don't leak" { NAME=keep; detect rocky-9; [ "$NAME" = keep ]; }

@test "by_family picks the family value, else the default" {
  FAMILY=rhel
  [ "$(by_family debian=a rhel=b default=c)" = b ]
  FAMILY=arch
  [ "$(by_family debian=a rhel=b default=c)" = c ]
}

@test "homebrew is refused for root and musl" {
  detect ubuntu-24.04
  TARGET_USER=root
  ! brew_supported
  TARGET_USER=someone
  IS_MUSL=true
  ! brew_supported
  IS_MUSL=false
  ARCH=amd64
  brew_supported
}
