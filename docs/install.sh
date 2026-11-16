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
ALL_PLUGINS="openviking-memory ov-wiki humanizer ponytail infra playwright"
MIN_NODE_MAJOR=18
NODE_LINE="v22"
NODE_DIST="https://nodejs.org/dist/latest-${NODE_LINE}.x"

ASSUME_YES=0
DRY_RUN=0
WANT_HOSTS=""
WANT_PLUGINS=""
CONFIGURE=1
REMOVE_DUPLICATES=0
TAB=$(printf '\t')

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
                          Default: every plugin in the catalog.
  --no-config             Do not offer to create ~/.openviking/ovcli.conf.
  --remove-duplicates     Remove what the purisev plugins make redundant: the
                          same plugin installed from another marketplace, and
                          loose skills a purisev plugin now ships, which move to
                          <skills dir>.replaced/<time>/. Without it they are
                          only listed.
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
      --remove-duplicates) REMOVE_DUPLICATES=1 ;;
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
    say "  openviking-memory and ponytail run their hooks with the bare node command."
    if confirm "Install the official Node.js $NODE_LINE build under ~/.local (no root needed)?"; then
      install_node
      if [ "$local_bin_was_on_path" -eq 0 ]; then
        warn "$HOME/.local/bin is not on your PATH. Add it to your shell profile, or the hosts will not find node."
      fi
    else
      warn "continuing without a usable node; openviking-memory stays inactive until Node.js $MIN_NODE_MAJOR or newer is on PATH, and ponytail's hooks fail"
    fi
  fi

  if have uv; then say "  uv: $(uv --version)"
  elif have python3; then say "  python3: $(python3 --version) (ov-wiki's optional offline helpers also need PyYAML; uv resolves it by itself)"
  else say "  neither uv nor python3: ov-wiki works without its optional offline helpers"
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

# The same text is in install.ps1; install.test.mjs keeps the two equal.
duplicates_js() {
  cat <<'JS'
// Finds what the purisev plugins make redundant on one host, given in PURISEV_HOST:
// a plugin of the same name installed from another marketplace out of the same
// repository, and a loose skill with the name of a skill a purisev plugin ships.
// Prints one tab-separated line per finding and changes nothing:
//   plugin       <id>    <purisev id>
//   marketplace  <name>  <ids installed from it, comma-separated>
//   skill        <dir>   <purisev id>
const { execSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const host = process.env.PURISEV_HOST;
const MARKETPLACE = "purisev";

const cli = (args) => {
  try {
    return JSON.parse(execSync(`${host} ${args}`, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }));
  } catch {
    return null;
  }
};
const readJson = (file) => {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
};
const catalog = (root) => readJson(path.join(root || "", ".claude-plugin", "marketplace.json"))?.plugins ?? [];

// host/owner/repo, whatever the spelling: owner/repo, https, ssh, with or without .git.
const repoKey = (value) => {
  if (!value) return null;
  const key = String(value).trim().toLowerCase()
    .replace(/^[a-z+]+:\/\//, "")
    .replace(/^[^/@]+@/, "")
    .replace(/^([^/:]+):(?!\d)/, "$1/")
    .replace(/\.git$/, "")
    .replace(/\/+$/, "");
  return /^[^/]+\.[^/]+\//.test(key) ? key : `github.com/${key}`;
};
// A relative source is the marketplace's own repository.
const entryRepo = (source, marketplaceRepo) => (typeof source === "string" ? marketplaceRepo : repoKey(source?.repo ?? source?.url));

function emit(installed, duplicates, skillDirs) {
  for (const plugin of duplicates) console.log(["plugin", plugin.id, `${plugin.name}@${MARKETPLACE}`].join("\t"));
  for (const name of new Set(duplicates.map((plugin) => plugin.marketplace))) {
    const ids = installed.filter((plugin) => plugin.marketplace === name).map((plugin) => plugin.id);
    console.log(["marketplace", name, ids.join(",")].join("\t"));
  }

  for (const plugin of installed.filter((p) => p.marketplace === MARKETPLACE && p.root)) {
    const names = [];
    if (fs.existsSync(path.join(plugin.root, "SKILL.md"))) names.push(plugin.name);
    const skills = path.join(plugin.root, "skills");
    if (fs.existsSync(skills)) {
      for (const dir of fs.readdirSync(skills)) if (fs.existsSync(path.join(skills, dir, "SKILL.md"))) names.push(dir);
    }
    for (const parent of skillDirs) {
      for (const name of names) {
        const dir = path.join(parent, name);
        if (fs.existsSync(path.join(dir, "SKILL.md"))) console.log(["skill", dir, plugin.id].join("\t"));
      }
    }
  }
}

function claude() {
  const marketplaces = cli("plugin marketplace list --json") ?? [];
  const ours = marketplaces.find((m) => m.name === MARKETPLACE);
  if (!ours) return;
  const reference = new Map(catalog(ours.installLocation).map((p) => [p.name, entryRepo(p.source, null)]));
  const installed = (cli("plugin list --json") ?? []).map((p) => {
    const at = p.id.indexOf("@");
    return { id: p.id, name: p.id.slice(0, at), marketplace: p.id.slice(at + 1), root: p.installPath };
  });
  const duplicates = installed.filter((plugin) => {
    if (plugin.marketplace === MARKETPLACE || !reference.get(plugin.name)) return false;
    const marketplace = marketplaces.find((m) => m.name === plugin.marketplace);
    const entry = marketplace && catalog(marketplace.installLocation).find((e) => e.name === plugin.name);
    return Boolean(entry) && entryRepo(entry.source, repoKey(marketplace.repo ?? marketplace.url)) === reference.get(plugin.name);
  });
  const config = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), ".claude");
  emit(installed, duplicates, [path.join(config, "skills")]);
}

function codex() {
  const marketplaces = cli("plugin marketplace list --json")?.marketplaces ?? [];
  const ours = marketplaces.find((m) => m.name === MARKETPLACE);
  if (!ours) return;
  const reference = new Map(catalog(ours.root).map((p) => [p.name, entryRepo(p.source, null)]));
  const home = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
  const installed = (cli("plugin list --json")?.installed ?? []).filter((p) => p.installed).map((p) => ({
    id: p.pluginId,
    name: p.name,
    marketplace: p.marketplaceName,
    root: path.join(home, "plugins", "cache", p.marketplaceName, p.name, String(p.version)),
    repo: p.source?.source === "local"
      ? (p.marketplaceSource?.sourceType === "git" ? repoKey(p.marketplaceSource.source) : null)
      : repoKey(p.source?.url),
  }));
  const duplicates = installed.filter((plugin) =>
    plugin.marketplace !== MARKETPLACE && Boolean(plugin.repo) && plugin.repo === reference.get(plugin.name));
  emit(installed, duplicates, [path.join(home, "skills"), path.join(os.homedir(), ".agents", "skills")]);
}

if (host === "claude") claude();
else if (host === "codex") codex();
JS
}

describe_duplicate() {
  case "$1" in
    plugin) say "  $2: another copy of $3" ;;
    skill) say "  $2: a loose copy of a skill $3 ships" ;;
  esac
}

move_skill() {
  dest="$(dirname "$1").replaced/$STAMP"
  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would move $1 to $dest/"
    return 0
  fi
  mkdir -p "$dest" && mv "$1" "$dest/" && say "  moved $1 to $dest/"
}

# Runs after the host's install, so the purisev copy is in place before another goes.
# A removal that fails is reported and the installer carries on.
handle_duplicates() {
  host=$1
  if ! node_is_usable; then
    warn "not looking for duplicates in $host: that needs node"
    return 0
  fi
  findings=$(PURISEV_HOST="$host" node -e "$(duplicates_js)" 2>/dev/null) || findings=""
  [ -n "$findings" ] || return 0

  step "Duplicates in $host"
  if [ "$REMOVE_DUPLICATES" -eq 0 ]; then
    printf '%s\n' "$findings" | while IFS="$TAB" read -r kind what owner; do describe_duplicate "$kind" "$what" "$owner"; done
    say "  Run the installer again with --remove-duplicates to remove them."
    return 0
  fi

  removed=""
  while IFS="$TAB" read -r kind what owner; do
    case "$kind" in
      plugin)
        if confirm "Remove $what, another copy of $owner?"; then
          case "$host" in claude) verb=uninstall ;; *) verb=remove ;; esac
          if run "$host" plugin "$verb" "$what" </dev/null; then removed="$removed $what"
          else warn "could not remove $what; continuing"
          fi
        else
          say "  keeping $what"
        fi ;;
      marketplace)
        # Removing a marketplace uninstalls everything from it, so only an emptied one goes.
        emptied=1
        for id in $(printf '%s' "$owner" | tr ',' ' '); do
          case " $removed " in *" $id "*) ;; *) emptied=0 ;; esac
        done
        if [ "$emptied" -eq 1 ]; then
          run "$host" plugin marketplace remove "$what" </dev/null || warn "could not remove the marketplace $what; continuing"
        fi ;;
      skill)
        if confirm "Move $what, a loose copy of a skill $owner ships, out of the way?"; then
          move_skill "$what" || warn "could not move $what; continuing"
        else
          say "  keeping $what"
        fi ;;
    esac
  done <<FINDINGS
$findings
FINDINGS
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
    say "  $conf does not exist. Create it with \"url\" and \"api_key\" (chmod 600)."
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
    say "  Codex: run /hooks once and approve the hooks openviking-memory and ponytail bring."
  fi
  say "  Check the setup with the ov-memory-doctor skill; it names anything still missing."
  say "  Documentation: https://ai-plugins.purisev.com"
}

main() {
  parse_args "$@"
  PLUGINS="${WANT_PLUGINS:-$ALL_PLUGINS}"
  STAMP=$(date +%Y%m%d-%H%M%S)
  if [ "$DRY_RUN" -eq 1 ]; then say "Dry run: nothing will be changed."; fi

  check_tools
  detect_hosts
  for host in $HOSTS; do
    case "$host" in
      claude) install_into_claude ;;
      codex) install_into_codex ;;
    esac
    handle_duplicates "$host"
  done
  configure_connection
  finish
}

main "$@"
