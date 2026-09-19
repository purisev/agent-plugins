#!/bin/sh
# Installer for the purisev agent plugins: https://ai-plugins.purisev.com
#
#   curl -fsSL https://ai-plugins.purisev.com/install.sh | sh
#   curl -fsSL https://ai-plugins.purisev.com/install.sh | sh -s -- --dry-run
#
# Everything lives in functions and main runs on the last line, so a download
# that stops halfway executes nothing.

set -eu

MARKETPLACE="purisev"
MARKETPLACE_REPO="purisev/agent-plugins"
ALL_PLUGINS="openviking-memory openviking-wiki"
MIN_NODE_MAJOR=18
NODE_LINE="v22"
NODE_DIST="https://nodejs.org/dist/latest-${NODE_LINE}.x"

ASSUME_YES=0
DRY_RUN=0
WANT_HOSTS=""
WANT_PLUGINS=""
CONFIGURE=1

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
Installs the purisev agent plugins into Claude Code and Codex.

Usage: install.sh [options]

  --host <claude|codex>   Install into this host only. Repeatable.
                          Default: every supported host found on PATH.
  --plugin <name>         Install this plugin only. Repeatable.
                          Default: openviking-memory and openviking-wiki.
  --no-config             Do not offer to create ~/.openviking/ovcli.conf.
  -y, --yes               Answer yes to every question. Nothing is asked, so
                          the connection file is not created either.
  --dry-run               Print what would be done and change nothing.
  -h, --help              Show this help.
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --host) [ $# -ge 2 ] || die "--host needs a value"; WANT_HOSTS="$WANT_HOSTS $2"; shift ;;
      --plugin) [ $# -ge 2 ] || die "--plugin needs a value"; WANT_PLUGINS="$WANT_PLUGINS $2"; shift ;;
      --no-config) CONFIGURE=0 ;;
      -y|--yes) ASSUME_YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "unknown option: $1" ;;
    esac
    shift
  done
  for host in $WANT_HOSTS; do
    case "$host" in claude|codex) ;; *) die "unknown host: $host (expected claude or codex)" ;; esac
  done
  for plugin in $WANT_PLUGINS; do
    case " $ALL_PLUGINS " in *" $plugin "*) ;; *) die "unknown plugin: $plugin (expected one of: $ALL_PLUGINS)" ;; esac
  done
}

# Under `curl | sh` stdin is the script itself, so questions go to the terminal.
# /dev/tty exists without a controlling terminal too, so it has to be opened to find out.
can_ask() { [ "$ASSUME_YES" -eq 0 ] && ( : >/dev/tty ) 2>/dev/null; }

confirm() {
  if [ "$ASSUME_YES" -eq 1 ]; then return 0; fi
  if ! can_ask; then return 1; fi
  printf '%s [y/N] ' "$1" >/dev/tty
  IFS= read -r reply </dev/tty || return 1
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

ask() {
  printf '%s: ' "$1" >/dev/tty
  IFS= read -r reply </dev/tty || reply=""
  printf '%s' "$reply"
}

ask_secret() {
  printf '%s: ' "$1" >/dev/tty
  stty -echo </dev/tty 2>/dev/null || true
  IFS= read -r reply </dev/tty || reply=""
  stty echo </dev/tty 2>/dev/null || true
  printf '\n' >/dev/tty
  printf '%s' "$reply"
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would run: $*"
    return 0
  fi
  say "  $*"
  "$@"
}

node_major() { node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true; }

node_is_usable() {
  have node || return 1
  major=$(node_major)
  case "$major" in ''|*[!0-9]*) return 1 ;; esac
  [ "$major" -ge "$MIN_NODE_MAJOR" ]
}

node_platform() {
  case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=darwin ;;
    *) return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) return 1 ;;
  esac
  printf '%s-%s' "$os" "$arch"
}

sha256_of() {
  if have sha256sum; then sha256sum "$1" | cut -d' ' -f1
  elif have shasum; then shasum -a 256 "$1" | cut -d' ' -f1
  else return 1
  fi
}

# The official build, checksum-verified, unpacked under ~/.local. No root and no
# package manager, so it cannot disturb a system Node.js.
install_node() {
  platform=$(node_platform) || die "no official Node.js build is known for $(uname -s) $(uname -m); install Node.js $MIN_NODE_MAJOR or newer yourself"
  have curl || die "curl is needed to download Node.js"
  have tar || die "tar is needed to unpack Node.js"

  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would download the latest Node.js $NODE_LINE for $platform from $NODE_DIST"
    say "  would verify it against SHASUMS256.txt and unpack it under $HOME/.local/lib/nodejs"
    say "  would link node, npm and npx into $HOME/.local/bin"
    return 0
  fi

  work=$(mktemp -d)
  sums="$work/SHASUMS256.txt"
  curl -fsSL "$NODE_DIST/SHASUMS256.txt" -o "$sums"
  archive=$(sed -n "s/^[0-9a-f]*  \(node-v[0-9.]*-$platform\.tar\.gz\)\$/\1/p" "$sums" | head -n 1)
  [ -n "$archive" ] || die "no Node.js $NODE_LINE archive for $platform is listed at $NODE_DIST"
  say "  downloading $NODE_DIST/$archive"
  curl -fsSL "$NODE_DIST/$archive" -o "$work/$archive"
  expected=$(sed -n "s/^\([0-9a-f]*\)  $archive\$/\1/p" "$sums")
  actual=$(sha256_of "$work/$archive") || die "neither sha256sum nor shasum is available to verify the download"
  [ "$expected" = "$actual" ] || die "checksum mismatch for $archive; nothing was installed"

  mkdir -p "$HOME/.local/lib/nodejs" "$HOME/.local/bin"
  tar -xzf "$work/$archive" -C "$HOME/.local/lib/nodejs"
  root="$HOME/.local/lib/nodejs/${archive%.tar.gz}"
  for tool in node npm npx; do ln -sfn "$root/bin/$tool" "$HOME/.local/bin/$tool"; done
  rm -rf "$work"
  PATH="$HOME/.local/bin:$PATH"
  export PATH
  say "  installed $("$HOME/.local/bin/node" --version) under $root"
}

path_has_local_bin() { case ":$PATH:" in *":$HOME/.local/bin:"*) return 0 ;; *) return 1 ;; esac; }

check_tools() {
  step "Checking tools"
  have git || die "git is not on PATH; the hosts clone plugins with it"
  say "  git: $(git --version)"

  local_bin_was_on_path=1
  path_has_local_bin || local_bin_was_on_path=0

  if node_is_usable; then
    say "  node: $(node --version)"
  else
    if have node; then say "  node: $(node --version) is older than $MIN_NODE_MAJOR"; else say "  node: not found"; fi
    say "  openviking-memory runs its hooks and MCP server with the bare node command."
    if confirm "Install the official Node.js $NODE_LINE build under ~/.local (no root needed)?"; then
      install_node
      if [ "$local_bin_was_on_path" -eq 0 ]; then
        warn "$HOME/.local/bin is not on your PATH. Add it to your shell profile, or the hosts will not find node."
      fi
    else
      warn "continuing without a usable node; openviking-memory stays inactive until Node.js $MIN_NODE_MAJOR or newer is on PATH"
    fi
  fi

  if have uv; then say "  uv: $(uv --version)"
  elif have python3; then say "  python3: $(python3 --version) (openviking-wiki's optional offline helpers also need PyYAML; uv resolves it by itself)"
  else say "  neither uv nor python3: openviking-wiki works without its optional offline helpers"
  fi
}

detect_hosts() {
  HOSTS=""
  if [ -n "$WANT_HOSTS" ]; then
    for host in $WANT_HOSTS; do
      have "$host" || die "$host was requested but is not on PATH"
      HOSTS="$HOSTS $host"
    done
    return 0
  fi
  for host in claude codex; do
    if have "$host"; then HOSTS="$HOSTS $host"; fi
  done
  [ -n "$HOSTS" ] || die "neither claude nor codex is on PATH; install Claude Code or Codex first"
}

install_into_claude() {
  step "Claude Code"
  if claude plugin marketplace list 2>/dev/null | grep -q "($MARKETPLACE_REPO)"; then
    run claude plugin marketplace update "$MARKETPLACE"
  else
    run claude plugin marketplace add "$MARKETPLACE_REPO"
  fi

  installed=$(claude plugin list --json 2>/dev/null || true)
  # The plugins were first published from marketplaces of their own; a copy from
  # there next to one from here would run every hook twice.
  for plugin in $ALL_PLUGINS; do
    old="$plugin@$plugin"
    case "$installed" in *"\"$old\""*)
      if confirm "Remove the earlier install $old, which would duplicate the hooks?"; then
        run claude plugin uninstall "$old"
        run claude plugin marketplace remove "$plugin"
      else
        warn "$old stays installed; disable one of the two copies yourself"
      fi ;;
    esac
  done

  for plugin in $PLUGINS; do
    case "$installed" in
      *"\"$plugin@$MARKETPLACE\""*) run claude plugin update "$plugin@$MARKETPLACE" ;;
      *) run claude plugin install "$plugin@$MARKETPLACE" ;;
    esac
  done
}

install_into_codex() {
  step "Codex"
  if codex plugin marketplace list 2>/dev/null | grep -q "^${MARKETPLACE}[[:space:]]"; then
    run codex plugin marketplace upgrade "$MARKETPLACE"
  else
    run codex plugin marketplace add "$MARKETPLACE_REPO"
  fi
  for plugin in $PLUGINS; do
    run codex plugin add "$plugin@$MARKETPLACE"
  done
  CODEX_INSTALLED=1
}

json_string() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

configure_connection() {
  [ "$CONFIGURE" -eq 1 ] || return 0
  case " $PLUGINS " in *" openviking-memory "*) ;; *) return 0 ;; esac
  conf="${OPENVIKING_CLI_CONFIG_FILE:-$HOME/.openviking/ovcli.conf}"

  step "Connection to OpenViking"
  if [ -f "$conf" ]; then
    say "  $conf exists; leaving it as it is"
    return 0
  fi
  if [ -n "${OPENVIKING_URL:-}" ] || [ -n "${OPENVIKING_BASE_URL:-}" ]; then
    say "  OPENVIKING_URL is set in this environment; not creating $conf"
    return 0
  fi
  if ! can_ask; then
    say "  $conf does not exist. Create it with \"url\" and \"api_key\" (chmod 600),"
    say "  or answer the connection prompts when Claude Code enables the plugin."
    return 0
  fi
  if ! confirm "Create $conf now? Claude Code and Codex both read it."; then return 0; fi

  url=$(ask "  OpenViking server URL (API root, for example https://openviking.example.com)")
  [ -n "$url" ] || { warn "no URL given; not creating $conf"; return 0; }
  key=$(ask_secret "  API key (a user or admin key; input is hidden)")
  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would write $conf with mode 600"
    return 0
  fi
  mkdir -p "$(dirname "$conf")"
  ( umask 077; printf '{\n  "url": "%s",\n  "api_key": "%s"\n}\n' "$(json_string "$url")" "$(json_string "$key")" >"$conf" )
  chmod 600 "$conf"
  say "  wrote $conf (mode 600)"
}

finish() {
  step "Done"
  say "  Restart the hosts so they load the plugins."
  if [ "${CODEX_INSTALLED:-0}" -eq 1 ]; then
    say "  Codex: run /hooks once and approve the hooks openviking-memory brings."
  fi
  say "  Check the setup with the ov-memory-doctor skill; it names anything still missing."
  say "  Documentation: https://ai-plugins.purisev.com"
}

main() {
  parse_args "$@"
  PLUGINS="${WANT_PLUGINS:-$ALL_PLUGINS}"
  if [ "$DRY_RUN" -eq 1 ]; then say "Dry run: nothing will be changed."; fi

  check_tools
  detect_hosts
  for host in $HOSTS; do
    case "$host" in
      claude) install_into_claude ;;
      codex) install_into_codex ;;
    esac
  done
  configure_connection
  finish
}

main "$@"
