#!/usr/bin/env bash
# NeoNano installer for Linux. Asks how you want to install, then does it.
#
#   curl -fsSL https://raw.githubusercontent.com/RenCupDotDev/NeoNano/main/install.sh | bash
#
# Or from a local copy of the repo:  bash install.sh
#
# Methods:
#   pipx    isolated install with pipx, command in ~/.local/bin   (recommended)
#   uv      isolated install with uv tool, command in ~/.local/bin
#   native  copies the files and writes a small launcher, no pip
#
# Options:
#   --pipx | --uv | --native   skip the menu and use this method
#   --tag vX.Y.Z               install this release (default: latest release)
#   --user | --system          native only: per-user (default unless root) or system-wide
#   --uninstall                remove neonano installed by any method, keep your config
#   --purge                    remove neonano and your config
#   -h, --help                 show this help
#
# Whichever method you pick, installs from the other methods are removed first,
# so only one nnano is ever on your PATH.
set -euo pipefail

APP=neonano
CMD=nnano
PKG=neonano
REPO="${NEONANO_REPO:-RenCupDotDev/NeoNano}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/$APP"
USER_BIN="$HOME/.local/bin"

METHOD=""
MODE=""
TAG=""
ACTION=install
PURGE=0
SRC=""
TMP_SRC=""
SUDO=""
SHARE_DIR=""
BIN_DIR=""
BIN=""

say()  { printf '==> %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
  if [ -n "$TMP_SRC" ]; then rm -rf "$TMP_SRC"; fi
  return 0
}
trap cleanup EXIT

while [ $# -gt 0 ]; do
  case "$1" in
    --pipx) METHOD=pipx ;;
    --uv) METHOD=uv ;;
    --native) METHOD=native ;;
    --user) MODE=user ;;
    --system) MODE=system ;;
    --tag)
      [ $# -ge 2 ] || die "--tag needs a version, e.g. --tag v0.2.1"
      TAG="$2"
      shift
      ;;
    --uninstall) ACTION=uninstall ;;
    --purge) ACTION=uninstall; PURGE=1 ;;
    -h|--help) sed -n '2,20p' "$0" 2>/dev/null || echo "see the README" ;  exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

# A local copy of the repo is used if the script sits next to one.
here="${BASH_SOURCE[0]:-$0}"
if [ -f "$here" ]; then
  d="$(cd "$(dirname "$here")" && pwd)"
  if [ -f "$d/pyproject.toml" ] && [ -f "$d/neonano/main.py" ]; then
    SRC="$d"
  fi
fi

# Latest release tag from GitHub (or the --tag value). Empty if unknown.
latest_tag() {
  if [ -n "$TAG" ]; then
    printf '%s\n' "$TAG"
    return 0
  fi
  have curl || return 0
  curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1 || true
  return 0
}

# What pipx and uv should install: the local copy, or the latest release from GitHub.
package_spec() {
  if [ -n "$SRC" ]; then
    printf '%s\n' "$SRC"
    return 0
  fi
  local t
  t="$(latest_tag)"
  if [ -n "$t" ]; then
    say "installing release $t from GitHub"
    printf 'git+https://github.com/%s.git@%s\n' "$REPO" "$t"
  else
    say "no release found, installing the main branch from GitHub"
    printf 'git+https://github.com/%s.git\n' "$REPO"
  fi
  return 0
}

choose_method() {
  if [ -n "$METHOD" ]; then return 0; fi
  [ -r /dev/tty ] || die "no terminal to ask on. Pass --pipx, --uv or --native."
  cat >&2 <<'MENU'

How do you want to install neonano?
  1) pipx     isolated install, recommended
  2) uv       isolated install with uv tool
  3) native   copies the files and writes a launcher, no pip
MENU
  local c=""
  printf 'choice [1]: ' >&2
  read -r c </dev/tty || die "could not read your choice. Pass --pipx, --uv or --native."
  case "${c:-1}" in
    1) METHOD=pipx ;;
    2) METHOD=uv ;;
    3) METHOD=native ;;
    *) die "invalid choice: $c" ;;
  esac
  return 0
}

check_python() {
  have python3 || die "python3 not found. Fedora: sudo dnf install python3"
  python3 -c 'import sys, curses, tomllib; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null \
    || die "python3 is too old or has no curses module. neonano needs Python 3.11+ with curses. Fedora: sudo dnf install python3 ncurses"
  return 0
}

check_tool() {
  case "$METHOD" in
    pipx) have pipx || die "pipx not found. Fedora: sudo dnf install pipx, then run: pipx ensurepath" ;;
    uv) have uv || die "uv not found. Install it with: curl -LsSf https://astral.sh/uv/install.sh | sh" ;;
  esac
  return 0
}

# Works out where a native install lives. System mode needs root or sudo.
native_paths() {
  if [ -z "$MODE" ]; then
    if [ "$(id -u)" -eq 0 ]; then MODE=system; else MODE=user; fi
  fi
  SUDO=""
  if [ "$MODE" = system ]; then
    if [ "$(id -u)" -ne 0 ]; then
      have sudo || die "a system install needs root. Run with sudo, or use --user."
      SUDO=sudo
    fi
    SHARE_DIR=/usr/local/share/$APP
    BIN_DIR=/usr/local/bin
  else
    SHARE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/$APP"
    BIN_DIR="$USER_BIN"
  fi
  BIN="$BIN_DIR/$CMD"
  case "$SHARE_DIR" in
    ""|/|"$HOME") die "refusing to use unsafe path: '$SHARE_DIR'" ;;
  esac
  return 0
}

# Removes native installs in both user and system locations.
native_remove() {
  local pair share bin sudo_cmd
  for pair in "${XDG_DATA_HOME:-$HOME/.local/share}/$APP|$USER_BIN/$CMD" "/usr/local/share/$APP|/usr/local/bin/$CMD"; do
    share="${pair%%|*}"
    bin="${pair#*|}"
    if [ -e "$share" ] || [ -e "$bin" ]; then
      sudo_cmd=""
      case "$share" in
        /usr/local/*) [ "$(id -u)" -eq 0 ] || sudo_cmd=sudo ;;
      esac
      say "removing native install: $bin and $share"
      if ! { $sudo_cmd rm -f "$bin" && $sudo_cmd rm -rf "$share"; }; then
        die "could not remove $share. Try: sudo bash install.sh --uninstall"
      fi
    fi
  done
  return 0
}

# Removes installs made by the other methods so only one nnano is on PATH.
remove_others() {
  local keep="$1"
  if [ "$keep" != pipx ] && have pipx; then
    if pipx uninstall "$PKG" >/dev/null 2>&1; then say "removed the pipx install"; fi
  fi
  if [ "$keep" != uv ] && have uv; then
    if uv tool uninstall "$PKG" >/dev/null 2>&1; then say "removed the uv install"; fi
  fi
  if [ "$keep" != native ]; then
    native_remove
  fi
  return 0
}

native_install() {
  local src="$SRC" t url ver py launcher
  if [ -z "$src" ]; then
    have tar || die "tar is required"
    TMP_SRC="$(mktemp -d)"
    t="$(latest_tag)"
    if [ -n "$t" ]; then
      url="https://github.com/$REPO/archive/refs/tags/$t.tar.gz"
    else
      url="https://github.com/$REPO/archive/refs/heads/main.tar.gz"
    fi
    say "downloading $url"
    if have curl; then
      curl -fsSL "$url" | tar -xz -C "$TMP_SRC" --strip-components=1
    elif have wget; then
      wget -qO- "$url" | tar -xz -C "$TMP_SRC" --strip-components=1
    else
      die "curl or wget is required to download neonano"
    fi
    src="$TMP_SRC"
  fi
  [ -f "$src/neonano/main.py" ] || die "source is missing neonano/main.py"
  ver="$(cat "$src/VERSION" 2>/dev/null || echo unknown)"
  py="$(command -v python3)"

  say "installing neonano $ver (native, $MODE) to $SHARE_DIR"
  $SUDO rm -rf "$SHARE_DIR"
  $SUDO mkdir -p "$SHARE_DIR" "$BIN_DIR"
  $SUDO cp -a "$src/neonano" "$SHARE_DIR"/
  $SUDO find "$SHARE_DIR" -name __pycache__ -type d -prune -exec rm -rf {} +

  launcher="$(mktemp)"
  cat > "$launcher" <<LAUNCH
#!/bin/sh
# nnano: starts neonano. Installed by install.sh (native).
case "\$1" in
  --version) echo "neonano $ver"; exit 0 ;;
esac
export PYTHONPATH="$SHARE_DIR\${PYTHONPATH:+:\$PYTHONPATH}"
exec "$py" -m neonano.main "\$@"
LAUNCH
  $SUDO install -m 755 "$launcher" "$BIN"
  rm -f "$launcher"
  return 0
}

uninstall_all() {
  if have pipx; then
    if pipx uninstall "$PKG" >/dev/null 2>&1; then say "removed the pipx install"; fi
  fi
  if have uv; then
    if uv tool uninstall "$PKG" >/dev/null 2>&1; then say "removed the uv install"; fi
  fi
  native_paths
  native_remove
  if [ "$PURGE" -eq 1 ]; then
    rm -rf "$CONFIG_DIR"
    say "config removed"
  else
    say "config kept in $CONFIG_DIR (use --purge to delete it)"
  fi
  say "neonano uninstalled"
  return 0
}

# ----- main -----

if [ "$ACTION" = uninstall ]; then
  uninstall_all
  exit 0
fi

choose_method
case "$METHOD" in
  pipx|uv|native) ;;
  *) die "unknown method: $METHOD" ;;
esac
check_python
check_tool
if [ "$METHOD" != native ] && [ "$(id -u)" -eq 0 ]; then
  die "run the $METHOD install as your normal user, not as root."
fi

case "$METHOD" in
  pipx)
    remove_others pipx
    say "installing with pipx"
    spec="$(package_spec)"
    pipx install --force "$spec"
    check="$USER_BIN/$CMD"
    ;;
  uv)
    remove_others uv
    say "installing with uv"
    spec="$(package_spec)"
    uv tool install --force "$spec"
    check="$USER_BIN/$CMD"
    ;;
  native)
    remove_others native
    native_paths
    native_install
    check="$BIN"
    ;;
esac

echo >&2
if [ -x "$check" ]; then
  say "$("$check" --version) installed at $check"
else
  say "installed, but $check was not found. Run: command -v nnano"
fi

case ":$PATH:" in
  *":$(dirname "$check"):"*) ;;
  *) printf '\nnote: %s is not in your PATH. Add this line to ~/.bashrc or ~/.zshrc, then open a new terminal:\n  export PATH="%s:$PATH"\n' "$(dirname "$check")" "$(dirname "$check")" >&2 ;;
esac

cat >&2 <<DONE

  start:   nnano [file]
  config:  $CONFIG_DIR/config.toml   (created on first run)
  update:  rerun this script; your config is kept
  remove:  bash install.sh --uninstall
DONE
