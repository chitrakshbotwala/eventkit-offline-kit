#!/usr/bin/env bash
# EventKit offline installer for macOS and Linux. Run from the kit folder:
#
#   bash install.sh                 # everything
#   bash install.sh --skip-app      # tools only
#   bash install.sh --only flutter,android
#   bash install.sh --root ~/somewhere/toolchain
#   bash install.sh --no-env        # don't edit ~/.profile, ~/.bashrc, ~/.zshrc
#
# Installs, from the files next to this script and without internet: EventKit, the Flutter
# SDK, Temurin JDK 17, the Android SDK (command-line tools, platform-tools, platform,
# build-tools), Google Chrome, VS Code and its Dart/Flutter extensions, and the workshop's
# starter project. Anything already installed that meets the event's requirements is left
# alone. Tools go where the EventKit app puts them (~/dev/toolchain), so the app finds and
# reuses them. Only Linux packages (EventKit .deb/.rpm, Chrome) ask for your sudo password.
#
# Not in the kit: git and the Xcode Command Line Tools on macOS, and the Linux build
# packages (clang, cmake, GTK headers...). They come from Apple or your distribution; the
# script tells you when they are missing and installs them if you are online.
#
# Written for bash 3.2 (the macOS default): no associative arrays, no mapfile.
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$KIT/payload"
ROOT=""
SKIP_APP=0
ONLY=""
NO_ENV=0

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --skip-app) SKIP_APP=1; shift ;;
    --no-env) NO_ENV=1; shift ;;
    --only) ONLY=",$2,"; shift 2 ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

# Android SDK license hashes, as `sdkmanager --licenses` writes them when you accept.
ANDROID_LICENSE_HASHES="24333f8a63b6825ea9c5514f83c2829b004d1fee d56f5187479451eabf01fb78af6dfcb131a6481e 8933bad161af4178b1185d1a37fbf41ea5269c55"

# --------------------------------------------------------------------------------------------
# Output

if [ -t 1 ]; then C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_OFF=$'\033[0m'
else C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_OFF=""; fi
step() { printf '\n%s== %s%s\n' "$C_CYAN" "$1" "$C_OFF"; }
ok()   { printf '   %sok%s    %s\n' "$C_GREEN" "$C_OFF" "$1"; }
info() { printf '   ..    %s\n' "$1"; }
warn() { printf '   %swarn%s  %s\n' "$C_YELLOW" "$C_OFF" "$1"; }
die()  { printf '%serror:%s %s\n' "$C_YELLOW" "$C_OFF" "$1" >&2; exit 1; }

SUMMARY=""
FAILED=0
result() { SUMMARY="${SUMMARY}$(printf '  %-18s %s' "$1" "$2")"$'\n'; }

# --------------------------------------------------------------------------------------------
# Target and kit index

case "$(uname -s)" in
  Darwin) OS=macos ;;
  Linux) OS=linux ;;
  *) die "unsupported system $(uname -s); on Windows run install-windows.cmd" ;;
esac
case "$(uname -m)" in
  arm64|aarch64) ARCH=arm64 ;;
  x86_64|amd64) ARCH=x64 ;;
  *) die "unsupported CPU $(uname -m)" ;;
esac
# A shell running under Rosetta reports x86_64 on Apple Silicon.
if [ "$OS" = macos ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then ARCH=arm64; fi
TARGET="$OS-$ARCH"
TSV="$PAYLOAD/targets/$TARGET.tsv"
[ -d "$PAYLOAD/targets" ] || die "no payload folder next to this script ($PAYLOAD). Build the kit first: node offline-kit/build-kit.mjs"
[ -f "$TSV" ] || die "this kit has no files for $TARGET"

TAB=$'\t'
meta() { awk -F'\t' -v k="$1" '$1=="meta" && $2==k { print $4; exit }' "$TSV"; }
# Rows of a kind (glob pattern): "file<TAB>sha256<TAB>arg" per line.
rows() { awk -F'\t' -v p="^$1$" '$1!="meta" && $1 ~ p { print $2 "\t" $3 "\t" $4 }' "$TSV"; }
row() { rows "$1" | head -n 1; }
wanted() { [ -z "$ONLY" ] || case "$ONLY" in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

VERIFIED=""
# kit_file "<file><TAB><sha256>..." -> absolute path, after checking the SHA-256.
kit_file() {
  local rel sha path
  rel="$(printf '%s' "$1" | cut -f1)"
  sha="$(printf '%s' "$1" | cut -f2)"
  [ -n "$rel" ] || die "the kit is missing a file for this step"
  path="$PAYLOAD/$rel"
  [ -f "$path" ] || die "missing from the kit: $rel"
  case "$VERIFIED" in *"|$path|"*) ;; *)
    info "checking $(basename "$path")" >&2
    [ "$(sha256_of "$path")" = "$sha" ] || die "$rel is corrupt (SHA-256 mismatch). Copy the kit again."
    VERIFIED="$VERIFIED|$path|"
  esac
  printf '%s' "$path"
}
row_arg() { printf '%s' "$1" | cut -f3; }

# --------------------------------------------------------------------------------------------
# Helpers

path_problem() {
  case "$1" in *[[:space:]]*) echo "contains spaces"; return ;; esac
  if printf '%s' "$1" | LC_ALL=C grep -q '[^ -~]'; then echo "contains non-ASCII characters"; return; fi
  if ! printf '%s' "$1" | LC_ALL=C grep -Eq '^[A-Za-z0-9._/~+@#$=,{}:-]+$'; then echo "contains special characters"; return; fi
}

writable() { mkdir -p "$1" 2>/dev/null && [ -w "$1" ]; }

first_existing() { for p in "$@"; do [ -n "$p" ] && [ -e "$p" ] && { printf '%s' "$p"; return 0; }; done; return 1; }

# Resolve symlinks (macOS has no readlink -f before 12.3).
real() {
  local p="$1" d
  while [ -L "$p" ]; do d="$(cd "$(dirname "$p")" && pwd)"; p="$(readlink "$p")"; case "$p" in /*) ;; *) p="$d/$p" ;; esac; done
  printf '%s' "$p"
}

unzip_to() {
  if command -v unzip >/dev/null 2>&1; then unzip -q -o "$1" -d "$2"
  elif command -v bsdtar >/dev/null 2>&1; then bsdtar -xf "$1" -C "$2"
  elif command -v python3 >/dev/null 2>&1; then python3 -m zipfile -e "$1" "$2"
  else die "no unzip tool found (install unzip)"; fi
}

extract() {
  local archive="$1" dest="$2"
  rm -rf "$dest"; mkdir -p "$dest"
  case "$archive" in
    *.zip|*.vsix) unzip_to "$archive" "$dest" ;;
    *.tar.xz) tar -xJf "$archive" -C "$dest" ;;
    *.tar.gz|*.tgz) tar -xzf "$archive" -C "$dest" ;;
    *) die "don't know how to extract $archive" ;;
  esac
}

single_child() {
  local n=0 only=""
  for d in "$1"/*/; do [ -d "$d" ] && { n=$((n + 1)); only="${d%/}"; }; done
  [ "$n" = 1 ] || die "unexpected archive layout in $1"
  printf '%s' "$only"
}

replace_dir() { rm -rf "$2"; mkdir -p "$(dirname "$2")"; mv "$1" "$2"; }

version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1)" = "$2" ]; }

online() { curl -fsS -m 5 -o /dev/null https://dl.google.com 2>/dev/null; }

SUDO=""
need_sudo() {
  if [ "$(id -u)" = 0 ]; then SUDO=""; return 0; fi
  command -v sudo >/dev/null 2>&1 || { warn "sudo is not available"; return 1; }
  SUDO="sudo"
}

pkg_manager() {
  for pm in apt-get dnf zypper pacman; do command -v "$pm" >/dev/null 2>&1 && { echo "$pm"; return 0; }; done
  return 0
}

# Environment changes, persisted at the end in the same managed block the app writes.
ENV_PATH=""   # colon-separated, in order
ENV_VARS=""   # lines of NAME=value
add_path() {
  case ":$ENV_PATH:" in *":$1:"*) ;; *) ENV_PATH="${ENV_PATH:+$ENV_PATH:}$1" ;; esac
  case ":$PATH:" in *":$1:"*) ;; *) PATH="$1:$PATH"; export PATH ;; esac
}
set_var() {
  ENV_VARS="$(printf '%s\n' "$ENV_VARS" | grep -v "^$1=" || true)"
  ENV_VARS="${ENV_VARS:+$ENV_VARS$'\n'}$1=$2"
  export "$1=$2"
}

BLOCK_START='# >>> eventkit toolchain >>> (managed by EventKit, do not edit)'
BLOCK_END='# <<< eventkit toolchain <<<'
dq() { printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"$`]/\\&/g')"; }

render_posix() {
  echo "$BLOCK_START"
  printf '%s\n' "$ENV_VARS" | sort | while IFS='=' read -r k v; do [ -n "$k" ] && echo "export $k=$(dq "$v")"; done
  if [ -n "$ENV_PATH" ]; then local q; q="$(dq "$ENV_PATH")"; echo "export PATH=${q%\"}:\$PATH\""; fi
  echo "$BLOCK_END"
}

render_fish() {
  echo "$BLOCK_START"
  printf '%s\n' "$ENV_VARS" | sort | while IFS='=' read -r k v; do [ -n "$k" ] && echo "set -gx $k '$(printf '%s' "$v" | sed "s/[\\\\']/\\\\&/g")'"; done
  printf '%s' "$ENV_PATH" | tr ':' '\n' | sed '1!G;h;$!d' | while read -r p; do [ -n "$p" ] && echo "fish_add_path --global --prepend '$p'"; done
  echo "$BLOCK_END"
}

# Insert or replace the managed block, leaving the rest of the file untouched.
upsert_block() {
  local file="$1" block="$2" tmp
  tmp="$(mktemp)"
  if [ -f "$file" ] && grep -qF "$BLOCK_START" "$file"; then
    # The block goes through ENVIRON: awk -v would eat its backslashes.
    EK_BLOCK="$block" awk -v s="$BLOCK_START" -v e="$BLOCK_END" '
      index($0, s) == 1 { print ENVIRON["EK_BLOCK"]; skip = 1; next }
      skip && index($0, e) == 1 { skip = 0; next }
      !skip { print }' "$file" > "$tmp"
  else
    { [ -f "$file" ] && cat "$file" && [ -s "$file" ] && echo; printf '%s\n' "$block"; } > "$tmp"
  fi
  mkdir -p "$(dirname "$file")"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

persist_env() {
  [ -n "$ENV_PATH$ENV_VARS" ] || return 0
  local posix fish
  posix="$(render_posix)"
  fish="$(render_fish)"
  # Same files the app manages: ~/.profile always, ~/.bashrc on Linux, ~/.zshrc on macOS,
  # ~/.bash_profile when it exists, and fish when it is set up.
  upsert_block "$HOME/.profile" "$posix"
  if [ "$OS" = linux ] || [ -f "$HOME/.bashrc" ]; then upsert_block "$HOME/.bashrc" "$posix"; fi
  if [ "$OS" = macos ] || [ -f "$HOME/.zshrc" ]; then upsert_block "$HOME/.zshrc" "$posix"; fi
  if [ -f "$HOME/.bash_profile" ]; then upsert_block "$HOME/.bash_profile" "$posix"; fi
  if [ -d "$HOME/.config/fish" ]; then upsert_block "$HOME/.config/fish/conf.d/eventkit.fish" "$fish"; fi
}

# --------------------------------------------------------------------------------------------
# Install root (same as the app: ~/dev/toolchain)

if [ -z "$ROOT" ]; then ROOT="$HOME/dev/toolchain"; fi
problem="$(path_problem "$ROOT")"
[ -z "$problem" ] || die "toolchain folder $ROOT $problem; pass another with --root"
writable "$ROOT" || die "toolchain folder $ROOT is not writable"
STAGING="$ROOT/.staging"
FLUTTER_DIR="$ROOT/flutter"
JDK_DIR="$ROOT/jdk-17"
SDK_DIR="$ROOT/android-sdk"
PROJECTS_DIR="$(dirname "$ROOT")/projects"
trap 'rm -rf "$STAGING"' EXIT

echo "EventKit offline installer ($TARGET)"
EVENT="$(meta event)"; [ -n "$EVENT" ] && echo "Event: $EVENT"
echo "Toolchain folder: $ROOT"
free_kb="$(df -Pk "$ROOT" | awk 'NR==2 {print $4}')"
if [ -n "$free_kb" ] && [ "$free_kb" -lt $((15 * 1024 * 1024)) ]; then
  warn "only $((free_kb / 1024 / 1024)) GB free; setup needs about 15 GB"
fi

# --------------------------------------------------------------------------------------------
# EventKit app

install_app() {
  if [ "$OS" = macos ]; then
    local app
    if app="$(first_existing /Applications/EventKit.app "$HOME/Applications/EventKit.app")"; then ok "EventKit already installed ($app)"; return 0; fi
    local dmg mount target
    dmg="$(kit_file "$(row app-dmg)")"
    info "installing EventKit $(meta appVersion)"
    mount="$(mktemp -d /tmp/ek-app.XXXXXX)"
    hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mount" "$dmg" >/dev/null
    target=/Applications; [ -w "$target" ] || { target="$HOME/Applications"; mkdir -p "$target"; }
    ditto "$mount/EventKit.app" "$target/EventKit.app"
    hdiutil detach "$mount" -force >/dev/null || true
    rmdir "$mount" 2>/dev/null || true
    ok "EventKit installed ($target/EventKit.app)"
    return 0
  fi
  if command -v eventkit >/dev/null 2>&1 || [ -e /opt/EventKit/eventkit ] || [ -e "$HOME/Applications/EventKit.AppImage" ]; then
    ok "EventKit already installed"; return 0
  fi
  local pm file
  pm="$(pkg_manager)"
  case "$pm" in
    apt-get) file="$(row app-deb)" ;;
    dnf|zypper) file="$(row app-rpm)" ;;
    pacman) file="$(row app-pacman)" ;;
    *) file="" ;;
  esac
  if [ -n "$file" ] && need_sudo; then
    file="$(kit_file "$file")"
    info "installing EventKit $(meta appVersion) with $pm (asks for your password)"
    local rc=0
    case "$pm" in
      apt-get) $SUDO apt-get install -y "$file" || rc=$? ;;
      dnf) $SUDO dnf install -y "$file" || rc=$? ;;
      zypper) $SUDO zypper --non-interactive install --allow-unsigned-rpm "$file" || rc=$? ;;
      pacman) $SUDO pacman -U --noconfirm "$file" || rc=$? ;;
    esac
    if [ "$rc" = 0 ]; then ok "EventKit installed"; return 0; fi
    warn "$pm could not install the package (missing dependencies need internet); using the AppImage"
  fi
  local appimage
  appimage="$(kit_file "$(row app-appimage)")"
  mkdir -p "$HOME/Applications" "$HOME/.local/share/applications"
  cp "$appimage" "$HOME/Applications/EventKit.AppImage"
  chmod +x "$HOME/Applications/EventKit.AppImage"
  cat > "$HOME/.local/share/applications/eventkit.desktop" <<EOF
[Desktop Entry]
Name=EventKit
Exec=$HOME/Applications/EventKit.AppImage %U
Type=Application
Categories=Development;
StartupWMClass=eventkit
EOF
  ok "EventKit installed ($HOME/Applications/EventKit.AppImage)"
}

# --------------------------------------------------------------------------------------------
# Git and system packages (not in the kit: they come from Apple or the distribution)

install_git() {
  local git="" min v
  min="$(meta gitMinVersion)"
  if [ "$OS" = macos ]; then
    # /usr/bin/git is a stub that opens an installer when the Command Line Tools are missing.
    git="$(first_existing /opt/homebrew/bin/git /usr/local/bin/git || true)"
    if [ -z "$git" ] && xcode-select -p >/dev/null 2>&1; then git=/usr/bin/git; fi
  else
    git="$(command -v git || true)"
  fi
  if [ -n "$git" ]; then
    v="$("$git" --version 2>/dev/null | sed -n 's/.*git version \([0-9][0-9.]*\).*/\1/p')"
    if [ -z "$min" ] || version_ge "$v" "$min"; then ok "git $v ($git)"; return 0; fi
    warn "git $v is older than $min"
  fi
  if [ "$OS" = macos ]; then
    warn "git needs Apple's Command Line Tools, which can't be bundled. When you are online run:"
    warn "    xcode-select --install"
    return 1
  fi
  install_linux_packages git
}

# Install distro packages when online; otherwise say what is missing.
install_linux_packages() {
  local pm list
  pm="$(pkg_manager)"
  case "$pm" in
    apt-get) list="$(meta linuxPackages.apt)" ;;
    dnf) list="$(meta linuxPackages.dnf)" ;;
    zypper) list="$(meta linuxPackages.zypper)" ;;
    pacman) list="$(meta linuxPackages.pacman)" ;;
    *) warn "unknown package manager; install: $*"; return 1 ;;
  esac
  [ -n "$list" ] || list="$*"
  if ! online; then
    warn "offline: install these with $pm when you are online, or let the EventKit app do it:"
    warn "    $list"
    return 1
  fi
  need_sudo || return 1
  info "installing system packages with $pm (asks for your password)"
  # shellcheck disable=SC2086
  case "$pm" in
    apt-get) $SUDO apt-get update && $SUDO apt-get install -y $list ;;
    dnf) $SUDO dnf install -y $list ;;
    zypper) $SUDO zypper --non-interactive install $list ;;
    pacman) $SUDO pacman -S --needed --noconfirm $list ;;
  esac
}

install_linux_deps() {
  local missing="" c
  for c in curl git unzip xz zip clang cmake ninja pkg-config; do
    command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
  done
  if [ -z "$missing" ]; then ok "build tools present"; return 0; fi
  info "missing:$missing"
  install_linux_packages $missing
}

# --------------------------------------------------------------------------------------------
# Flutter

flutter_bin() { printf '%s' "$FLUTTER_DIR/bin/flutter"; }

# Prints "<frameworkVersion> <channel> <flutterRoot>" or nothing.
flutter_info() {
  local out
  out="$("$1" --version --machine 2>/dev/null)" || return 0
  printf '%s' "$out" | tr -d '\n' | sed -n 's/.*"frameworkVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 | tr -d '\n'
  printf ' '
  printf '%s' "$out" | tr -d '\n' | sed -n 's/.*"channel"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tr -d '\n'
  printf ' '
  printf '%s' "$out" | tr -d '\n' | sed -n 's/.*"flutterRoot"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tr -d '\n'
}

install_flutter() {
  local want pinned bin info v ch root skip
  want="$(meta flutterVersion)"
  pinned="$(meta flutterPinned)"
  for bin in "${FLUTTER_ROOT:+$FLUTTER_ROOT/bin/flutter}" "$(command -v flutter >/dev/null 2>&1 && real "$(command -v flutter)")" "$(flutter_bin)"; do
    [ -n "$bin" ] && [ -x "$bin" ] || continue
    info "checking Flutter at $bin"
    info="$(flutter_info "$bin")"
    v="$(echo "$info" | awk '{print $1}')"; ch="$(echo "$info" | awk '{print $2}')"; root="$(echo "$info" | awk '{print $3}')"
    [ -n "$v" ] || continue
    [ -n "$root" ] || root="$(cd "$(dirname "$bin")/.." && pwd)"
    skip="$(path_problem "$root")"
    [ -z "$skip" ] && [ "$ch" != stable ] && skip="channel $ch"
    [ -z "$skip" ] && [ "$pinned" = true ] && [ "$v" != "$want" ] && skip="version $v, event requires $want"
    if [ -n "$skip" ]; then info "not using Flutter at $root: $skip"; continue; fi
    FLUTTER_DIR="$root"
    add_path "$root/bin"
    ok "Flutter $v ($root)"
    return 0
  done
  local archive stage extracted
  archive="$(kit_file "$(row 'flutter-.*')")"
  info "extracting Flutter $want (a few minutes)"
  stage="$STAGING/flutter"
  extract "$archive" "$stage"
  if [ -d "$stage/flutter/bin" ]; then extracted="$stage/flutter"; else extracted="$(single_child "$stage")"; fi
  FLUTTER_DIR="$ROOT/flutter"
  replace_dir "$extracted" "$FLUTTER_DIR"
  add_path "$FLUTTER_DIR/bin"
  command -v git >/dev/null 2>&1 && git config --global --add safe.directory "$FLUTTER_DIR" || true
  if [ "$OS" = macos ] && [ "$ARCH" = arm64 ] && ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
    warn "Rosetta 2 is not installed. Some Flutter tools need it; when online run:"
    warn "    softwareupdate --install-rosetta --agree-to-license"
  fi
  info "first run of flutter (builds the tool, no download)"
  "$(flutter_bin)" config --no-analytics >/dev/null 2>&1 || true
  "$(flutter_bin)" --disable-analytics >/dev/null 2>&1 || true
  v="$(flutter_info "$(flutter_bin)" | awk '{print $1}')"
  [ -n "$v" ] || { warn "Flutter was extracted but 'flutter --version' failed (is git installed?)"; return 1; }
  ok "Flutter $v installed"
}

# --------------------------------------------------------------------------------------------
# Java

java_major() {
  local v
  v="$("$1" -version 2>&1 | sed -n 's/.*version "\([0-9][0-9._]*\).*/\1/p' | head -n 1)"
  case "$v" in 1.*) v="${v#1.}" ;; esac
  printf '%s' "${v%%[._]*}"
}

# JAVA_HOME for a JDK folder (macOS JDKs nest under Contents/Home).
java_home_of() { if [ "$OS" = macos ] && [ -d "$1/Contents/Home" ]; then printf '%s' "$1/Contents/Home"; else printf '%s' "$1"; fi; }

install_java() {
  local min h m home java_on_path=""
  min="$(meta javaMajor)"
  command -v java >/dev/null 2>&1 && java_on_path="$(dirname "$(dirname "$(real "$(command -v java)")")")"
  for h in "${JAVA_HOME:-}" \
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home" "$HOME/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
    /opt/android-studio/jbr "$HOME/android-studio/jbr" /snap/android-studio/current/jbr \
    "$java_on_path" "$(java_home_of "$JDK_DIR")"; do
    [ -n "$h" ] && [ -x "$h/bin/java" ] || continue
    # macOS /usr/bin/java is a stub that pops up a dialog when no JDK exists.
    [ "$h" = /usr ] && [ "$OS" = macos ] && continue
    m="$(java_major "$h/bin/java")"
    if [ -n "$m" ] && [ "$m" -ge "$min" ] && [ "$m" -le 21 ]; then
      set_var JAVA_HOME "$h"
      add_path "$h/bin"
      ok "Java $m ($h)"
      return 0
    fi
    [ -n "$m" ] && info "not using Java $m at $h"
  done
  local archive stage
  archive="$(kit_file "$(row 'java-.*')")"
  info "extracting Temurin JDK"
  stage="$STAGING/jdk"
  extract "$archive" "$stage"
  replace_dir "$(single_child "$stage")" "$JDK_DIR"
  home="$(java_home_of "$JDK_DIR")"
  set_var JAVA_HOME "$home"
  add_path "$home/bin"
  ok "Java $(java_major "$home/bin/java") installed"
}

# --------------------------------------------------------------------------------------------
# Android SDK

find_android_sdk() {
  local sdk d default
  if [ "$OS" = macos ]; then default="$HOME/Library/Android/sdk"; else default="$HOME/Android/Sdk"; fi
  for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$default"; do
    [ -n "$sdk" ] || continue
    for d in platform-tools platforms build-tools cmdline-tools; do
      if [ -e "$sdk/$d" ]; then
        if [ -n "$(path_problem "$sdk")" ]; then info "not using Android SDK at $sdk: $(path_problem "$sdk")"; break; fi
        printf '%s' "$sdk"; return 0
      fi
    done
  done
  return 1
}

install_android() {
  local sdk changed=0 stage line dest pkg file h
  sdk="$(find_android_sdk || true)"
  [ -n "$sdk" ] || sdk="$SDK_DIR"
  SDK_DIR="$sdk"
  mkdir -p "$sdk"

  if [ ! -x "$sdk/cmdline-tools/latest/bin/sdkmanager" ]; then
    info "extracting Android command-line tools"
    stage="$STAGING/cmdline-tools"
    file="$(kit_file "$(row android-cmdline-tools)")"
    extract "$file" "$stage"
    [ -d "$stage/cmdline-tools/bin" ] || die "cmdline-tools archive layout unexpected"
    replace_dir "$stage/cmdline-tools" "$sdk/cmdline-tools/latest"
    changed=1
  fi

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    pkg="$(row_arg "$line")"
    dest="$sdk/$(printf '%s' "$pkg" | tr ';' '/')"
    [ -e "$dest" ] && continue
    info "installing $pkg"
    file="$(kit_file "$line")"
    stage="$STAGING/android-package"
    extract "$file" "$stage"
    # Archives hold one folder whose name doesn't matter (e.g. android-16 for build-tools 36).
    replace_dir "$(single_child "$stage")" "$dest"
    changed=1
  done <<EOF
$(rows android-package)
EOF

  mkdir -p "$sdk/licenses"
  touch "$sdk/licenses/android-sdk-license"
  for h in $ANDROID_LICENSE_HASHES; do
    # Writing the hash is what accepting the Android SDK License in sdkmanager does.
    grep -q "$h" "$sdk/licenses/android-sdk-license" || printf '\n%s' "$h" >> "$sdk/licenses/android-sdk-license"
  done

  set_var ANDROID_HOME "$sdk"
  set_var ANDROID_SDK_ROOT "$sdk"
  add_path "$sdk/platform-tools"
  add_path "$sdk/cmdline-tools/latest/bin"
  if [ -x "$(flutter_bin)" ]; then
    "$(flutter_bin)" config --android-sdk="$sdk" >/dev/null 2>&1 || true
    [ -n "${JAVA_HOME:-}" ] && { "$(flutter_bin)" config --jdk-dir="$JAVA_HOME" >/dev/null 2>&1 || true; }
  fi
  if [ "$changed" = 1 ]; then ok "Android SDK installed ($sdk)"; else ok "Android SDK ($sdk)"; fi
}

# --------------------------------------------------------------------------------------------
# Chrome

find_chrome() {
  if [ "$OS" = macos ]; then
    first_existing "/Applications/Google Chrome.app" "$HOME/Applications/Google Chrome.app"
  else
    first_existing /usr/bin/google-chrome /usr/bin/google-chrome-stable /opt/google/chrome/chrome \
      /usr/bin/chromium /usr/bin/chromium-browser /snap/bin/chromium /var/lib/flatpak/exports/bin/com.google.Chrome
  fi
}

install_chrome() {
  local c
  if c="$(find_chrome)"; then ok "Chrome ($c)"; return 0; fi
  if [ "$OS" = macos ]; then
    local dmg mount target
    dmg="$(kit_file "$(row chrome-dmg)")"
    info "copying Google Chrome to Applications"
    mount="$(mktemp -d /tmp/ek-chrome.XXXXXX)"
    hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mount" "$dmg" >/dev/null
    target=/Applications; [ -w "$target" ] || { target="$HOME/Applications"; mkdir -p "$target"; }
    ditto "$mount/Google Chrome.app" "$target/Google Chrome.app"
    hdiutil detach "$mount" -force >/dev/null || true
    rmdir "$mount" 2>/dev/null || true
    ok "Google Chrome installed"
    return 0
  fi
  local pm file
  pm="$(pkg_manager)"
  case "$pm" in
    apt-get) file="$(row chrome-deb)" ;;
    dnf|zypper) file="$(row chrome-rpm)" ;;
    *) warn "no Chrome package for ${pm:-this distribution} in the kit; install chromium from your distribution when online"; return 1 ;;
  esac
  need_sudo || return 1
  file="$(kit_file "$file")"
  info "installing Google Chrome with $pm (asks for your password)"
  case "$pm" in
    apt-get) $SUDO apt-get install -y "$file" ;;
    dnf) $SUDO dnf install -y "$file" ;;
    zypper) $SUDO zypper --non-interactive install --allow-unsigned-rpm "$file" ;;
  esac
  ok "Google Chrome installed"
}

# --------------------------------------------------------------------------------------------
# VS Code + extensions

find_code() {
  if [ "$OS" = macos ]; then
    local cli="Contents/Resources/app/bin/code"
    first_existing "/Applications/Visual Studio Code.app/$cli" "$HOME/Applications/Visual Studio Code.app/$cli"
  else
    first_existing "$ROOT/vscode/bin/code" /usr/share/code/bin/code /snap/bin/code "$(command -v code || true)"
  fi
}

install_vscode() {
  local cli archive stage target line ext have vsix
  if ! cli="$(find_code)"; then
    archive="$(kit_file "$(row 'vscode-.*')")"
    info "extracting VS Code"
    stage="$STAGING/vscode"
    extract "$archive" "$stage"
    if [ "$OS" = macos ]; then
      target=/Applications; [ -w "$target" ] || { target="$HOME/Applications"; mkdir -p "$target"; }
      replace_dir "$stage/Visual Studio Code.app" "$target/Visual Studio Code.app"
    else
      replace_dir "$(single_child "$stage")" "$ROOT/vscode"
      mkdir -p "$HOME/.local/share/applications"
      cat > "$HOME/.local/share/applications/eventkit-vscode.desktop" <<EOF
[Desktop Entry]
Name=Visual Studio Code
Comment=Code Editing. Redefined.
Exec=$ROOT/vscode/code %F
Icon=$ROOT/vscode/resources/app/resources/linux/code.png
Type=Application
Categories=Development;IDE;
EOF
    fi
    cli="$(find_code)" || die "VS Code was installed but its command-line launcher was not found"
  fi
  add_path "$(dirname "$cli")"
  have="$("$cli" --list-extensions 2>/dev/null | tr 'A-Z' 'a-z' || true)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ext="$(row_arg "$line")"
    printf '%s\n' "$have" | grep -qx "$(printf '%s' "$ext" | tr 'A-Z' 'a-z')" && continue
    info "installing extension $ext"
    vsix="$(kit_file "$line")"
    "$cli" --install-extension "$vsix" --force >/dev/null
  done <<EOF
$(rows vscode-extension)
EOF
  ok "VS Code with the Dart and Flutter extensions"
}

# --------------------------------------------------------------------------------------------
# Starter project (the app runs `flutter pub get` and the Gradle warm-up on it later)

install_starter() {
  local line name sha dir stage src file
  line="$(row starter-project)"
  [ -n "$line" ] || return 0
  name="$(row_arg "$line")"
  sha="$(meta starterSha256)"
  dir="$PROJECTS_DIR/$name"
  if [ -f "$dir/pubspec.yaml" ] && [ "$(cat "$dir/.eventkit-starter" 2>/dev/null | tr -d '[:space:]')" = "$sha" ]; then
    ok "starter project ($dir)"; return 0
  fi
  if [ -e "$dir" ]; then
    # Never delete attendee work: keep the previous copy next to the new one.
    mv "$dir" "$dir-backup-$(date +%Y%m%d-%H%M%S)"
    info "kept previous project next to it"
  fi
  stage="$STAGING/starter"
  file="$(kit_file "$line")"
  extract "$file" "$stage"
  if [ -f "$stage/pubspec.yaml" ]; then src="$stage"; else
    src="$(for d in "$stage"/*/; do [ -f "$d/pubspec.yaml" ] && { printf '%s' "${d%/}"; break; }; done)"
    [ -n "$src" ] || die "the starter project zip has no pubspec.yaml"
  fi
  replace_dir "$src" "$dir"
  printf '%s' "$sha" > "$dir/.eventkit-starter"
  ok "starter project ($dir)"
}

# --------------------------------------------------------------------------------------------

run_step() {
  local name="$1" title="$2" fn="$3"
  wanted "$name" || return 0
  step "$title"
  # Each step runs in a subshell so one failure (or die) doesn't stop the others; the
  # environment it sets up is passed back through a file.
  local envfile rc
  envfile="$(mktemp)"
  # Not `( ... ) || rc=$?`: bash ignores set -e inside a subshell that is part of a || list.
  set +e
  (
    set -eE
    # Name the command that stopped the step; skip deliberate `return 1` and failures inside
    # command substitutions (BASH_SUBSHELL > 1), which are expected while probing.
    trap '[ "$BASH_SUBSHELL" -gt 1 ] || case "$BASH_COMMAND" in return*) ;; *) warn "stopped: \"$BASH_COMMAND\" failed (line $LINENO)" ;; esac' ERR
    "$fn"
    { printf 'ENV_PATH=%q\n' "$ENV_PATH"; printf 'ENV_VARS=%q\n' "$ENV_VARS"
      printf 'FLUTTER_DIR=%q\n' "$FLUTTER_DIR"; printf 'SDK_DIR=%q\n' "$SDK_DIR"; printf 'VERIFIED=%q\n' "$VERIFIED"
      [ -n "${JAVA_HOME:-}" ] && printf 'export JAVA_HOME=%q\n' "$JAVA_HOME"; printf 'export PATH=%q\n' "$PATH"; } > "$envfile"
  )
  rc=$?
  set -e
  if [ "$rc" = 0 ]; then
    # shellcheck disable=SC1090
    . "$envfile"
    result "$title" ok
  else
    FAILED=1
    result "$title" FAILED
  fi
  rm -f "$envfile"
}

[ "$SKIP_APP" = 1 ] || run_step app "EventKit app" install_app
[ "$OS" = linux ] && run_step linux-deps "System packages" install_linux_deps
run_step git "Git" install_git
run_step flutter "Flutter SDK" install_flutter
run_step java "Java (JDK 17)" install_java
run_step android "Android SDK" install_android
run_step chrome "Google Chrome" install_chrome
run_step vscode "VS Code" install_vscode
run_step starter "Starter project" install_starter

# The JDK may have been picked after Flutter was configured.
if [ -x "$(flutter_bin)" ] && [ -n "${JAVA_HOME:-}" ]; then
  "$(flutter_bin)" config --jdk-dir="$JAVA_HOME" >/dev/null 2>&1 || true
fi
[ "$NO_ENV" = 1 ] || persist_env

step "Summary"
printf '%s' "$SUMMARY"
echo
if [ "$FAILED" = 1 ]; then
  echo "${C_YELLOW}Some steps failed. Fix the problem above and run the installer again, or let the EventKit"
  echo "app finish them when you are online.${C_OFF}"
  exit 1
fi
echo "${C_GREEN}All done. Open EventKit and sign in with Google (needs internet once). Setup will find"
echo "these tools and only fetch what is left (Dart packages and the Gradle warm-up).${C_OFF}"
echo "Open a new terminal window to use flutter from the command line."
