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
# Installed only on request, or when a host already has them.
OPTIONAL_PLUGINS="langfuse-observability"
LANGFUSE_PLUGIN="langfuse-observability"
MIN_NODE_MAJOR=18
NODE_LINE="v22"
NODE_DIST="https://nodejs.org/dist/latest-${NODE_LINE}.x"
# Codex runs the Langfuse hook on this Node.js; the other hooks need MIN_NODE_MAJOR.
LANGFUSE_CODEX_NODE_MAJOR=22
UV_DIST="https://github.com/astral-sh/uv/releases/latest/download"
# How long Claude Code waits at exit for the Langfuse hook, which sends the session's last turn then.
SESSIONEND_TIMEOUT_MS=15000

ASSUME_YES=0
DRY_RUN=0
WANT_HOSTS=""
WANT_PLUGINS=""
CONFIGURE=1
REMOVE_DUPLICATES=0
WANT_LANGFUSE=0
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
                          Default: every plugin in the catalog except
                          langfuse-observability.
  --langfuse              Also install langfuse-observability, which sends
                          every session to your Langfuse server, and save its
                          keys. They come from LANGFUSE_BASE_URL,
                          LANGFUSE_PUBLIC_KEY and LANGFUSE_SECRET_KEY, or are
                          asked for.
  --no-config             Do not set up the connections to OpenViking and
                          Langfuse.
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
      --langfuse) WANT_LANGFUSE=1 ;;
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
    case " $ALL_PLUGINS $OPTIONAL_PLUGINS " in *" $plugin "*) ;; *) die "unknown plugin: $plugin (expected one of: $ALL_PLUGINS $OPTIONAL_PLUGINS)" ;; esac
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
  [ "$major" -ge "${1:-$MIN_NODE_MAJOR}" ]
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
# Links node, npm and npx, or only the tools named in $1.
install_node() {
  tools=${1:-node npm npx}
  platform=$(node_platform) || die "no official Node.js build is known for $(uname -s) $(uname -m); install Node.js $MIN_NODE_MAJOR or newer yourself"
  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would download the latest Node.js $NODE_LINE for $platform from $NODE_DIST"
    say "  would verify it against SHASUMS256.txt and unpack it under $HOME/.local/lib/nodejs"
    say "  would link $tools into $HOME/.local/bin"
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
  for tool in $tools; do ln -sfn "$root/bin/$tool" "$HOME/.local/bin/$tool"; done
  rm -rf "$work"
  PATH="$HOME/.local/bin:$PATH"
  export PATH
  say "  installed $tools from ${archive%.tar.gz} under $root"
}

path_has_local_bin() { case ":$PATH:" in *":$HOME/.local/bin:"*) return 0 ;; *) return 1 ;; esac; }

selected() { case " $PLUGINS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
on_host() { case " $HOSTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# On macOS /usr/bin/git exists before the developer tools do, and fails when run.
git_works() { have git && git --version >/dev/null 2>&1; }

package_manager() {
  for pm in apt-get dnf yum zypper pacman apk brew; do
    if have "$pm"; then printf '%s' "$pm"; return 0; fi
  done
  return 1
}

as_root() {
  if [ "$(id -u)" -eq 0 ]; then run "$@"; else run sudo "$@"; fi
}

# Installs system packages, asking first. Returns 1 when they cannot be installed or the answer is no.
install_packages() {
  if ! pm=$(package_manager); then
    if [ "$(uname -s)" = Darwin ]; then
      warn "$1: not installed. Run xcode-select --install, which brings git with the developer tools, or install Homebrew"
    else
      warn "$1: not installed, and no supported package manager (apt-get, dnf, yum, zypper, pacman, apk) was found"
    fi
    return 1
  fi
  how="with $pm"
  if [ "$pm" != brew ] && [ "$(id -u)" -ne 0 ]; then
    if ! have sudo; then
      warn "$1: installing with $pm needs root, and sudo is not available"
      return 1
    fi
    how="with sudo $pm"
  fi
  confirm "Install $1 $how?" || return 1
  # shellcheck disable=SC2086 # $1 is a list of package names
  case "$pm" in
    apt-get)
      if [ -z "${APT_UPDATED:-}" ]; then as_root apt-get update -qq && APT_UPDATED=1; fi
      as_root apt-get install -y -qq $1 ;;
    dnf|yum) as_root "$pm" install -y $1 ;;
    zypper) as_root zypper --non-interactive install $1 ;;
    pacman) as_root pacman -S --noconfirm --needed $1 ;;
    apk) as_root apk add $1 ;;
    brew) run brew install $1 ;;
  esac
}

# curl and tar fetch and unpack the Node.js and uv builds.
download_tools_ready() {
  missing=""
  have curl || missing="curl"
  have tar || missing="${missing:+$missing }tar"
  [ -n "$missing" ] || return 0
  say "  $missing: not found; needed to download it"
  install_packages "$missing" || return 1
  [ "$DRY_RUN" -eq 1 ] || { have curl && have tar; }
}

uv_target() {
  case "$(uname -s)" in
    Linux) os=unknown-linux-musl ;;
    Darwin) os=apple-darwin ;;
    *) return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) return 1 ;;
  esac
  printf '%s-%s' "$arch" "$os"
}

# The official build, checksum-verified, into ~/.local/bin, where uv's own installer puts it.
install_uv() {
  target=$(uv_target) || die "no official uv build is known for $(uname -s) $(uname -m); install uv yourself"
  archive="uv-$target.tar.gz"
  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would download $UV_DIST/$archive"
    say "  would verify it against $archive.sha256 and put uv and uvx into $HOME/.local/bin"
    return 0
  fi

  work=$(mktemp -d)
  say "  downloading $UV_DIST/$archive"
  curl -fsSL "$UV_DIST/$archive" -o "$work/$archive"
  curl -fsSL "$UV_DIST/$archive.sha256" -o "$work/$archive.sha256"
  expected=$(cut -d' ' -f1 <"$work/$archive.sha256")
  actual=$(sha256_of "$work/$archive") || die "neither sha256sum nor shasum is available to verify the download"
  [ "$expected" = "$actual" ] || die "checksum mismatch for $archive; nothing was installed"

  tar -xzf "$work/$archive" -C "$work"
  mkdir -p "$HOME/.local/bin"
  for tool in uv uvx; do cp "$work/uv-$target/$tool" "$HOME/.local/bin/$tool" && chmod 755 "$HOME/.local/bin/$tool"; done
  rm -rf "$work"
  PATH="$HOME/.local/bin:$PATH"
  export PATH
  say "  installed $("$HOME/.local/bin/uv" --version) into $HOME/.local/bin"
}

installed_into_local_bin() { LOCAL_BIN_TOOLS="${LOCAL_BIN_TOOLS:+$LOCAL_BIN_TOOLS and }$1"; }

check_git() {
  if git_works; then
    say "  git: $(git --version)"
    return 0
  fi
  say "  git: not found; the hosts clone plugins with it"
  install_packages git || die "git is needed; install it, then run this installer again"
  if [ "$DRY_RUN" -eq 1 ]; then return 0; fi
  git_works || die "git is still not on PATH after installing it; open a new terminal and run this installer again"
  say "  git: $(git --version)"
}

check_node() {
  need=$MIN_NODE_MAJOR
  if selected "$LANGFUSE_PLUGIN" && on_host codex; then need=$LANGFUSE_CODEX_NODE_MAJOR; fi
  if node_is_usable "$need"; then
    say "  node: $(node --version)"
    check_npm
    return 0
  fi
  if have node; then say "  node: $(node --version) is older than $need"; else say "  node: not found"; fi
  if [ "$need" -gt "$MIN_NODE_MAJOR" ]; then
    say "  Codex runs the Langfuse hook on Node.js $need or newer."
    without="Codex sends no traces to Langfuse until Node.js $need or newer is on PATH"
  else
    say "  openviking-memory and ponytail run their hooks with the bare node command."
    without="openviking-memory stays inactive until Node.js $MIN_NODE_MAJOR or newer is on PATH, and ponytail's hooks fail"
  fi
  if confirm "Install the official Node.js $NODE_LINE build under ~/.local (no root needed)?" && download_tools_ready; then
    install_node
    installed_into_local_bin node
  else
    warn "continuing without a usable node; $without"
  fi
}

# Codex installs Langfuse's plugin with npm pack. A node without npm gets npm from the official build,
# which runs on that node and leaves it in place.
check_npm() {
  if ! selected "$LANGFUSE_PLUGIN" || ! on_host codex; then return 0; fi
  if have npm; then
    say "  npm: $(npm --version)"
    return 0
  fi
  say "  npm: not found; Codex installs Langfuse's plugin with it"
  if confirm "Add npm and npx from the official Node.js $NODE_LINE build to ~/.local/bin (no root needed)?" && download_tools_ready; then
    install_node "npm npx"
    installed_into_local_bin npm
  else
    warn "continuing without npm; Codex does not get Langfuse's plugin until npm is on PATH"
  fi
}

check_uv() {
  if have uv; then
    say "  uv: $(uv --version)"
  elif selected "$LANGFUSE_PLUGIN" && on_host claude; then
    say "  uv: not found; Claude Code runs the Langfuse hook with it"
    if confirm "Install the official uv build into ~/.local/bin (no root needed)?" && download_tools_ready; then
      install_uv
      installed_into_local_bin uv
    else
      warn "continuing without uv; Claude Code sends no traces to Langfuse until uv is on PATH"
    fi
  elif have python3; then
    say "  python3: $(python3 --version) (ov-wiki's optional offline helpers also need PyYAML; uv resolves it by itself)"
  else
    say "  neither uv nor python3: ov-wiki works without its optional offline helpers"
  fi
}

# Runs once the hosts and plugins are known, so it installs what they need and nothing else.
check_tools() {
  step "Checking tools"
  local_bin_was_on_path=1
  path_has_local_bin || local_bin_was_on_path=0
  check_git
  check_node
  check_uv
  if [ -n "${LOCAL_BIN_TOOLS:-}" ] && [ "$local_bin_was_on_path" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    warn "$HOME/.local/bin is not on your PATH, so the hosts will not find $LOCAL_BIN_TOOLS. Add this line to your shell profile: export PATH=\"\$HOME/.local/bin:\$PATH\""
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

# Codex installs a plugin only under the name in its manifest, and Langfuse's Codex plugin is called tracing.
codex_name() {
  case "$1" in
    "$LANGFUSE_PLUGIN") printf 'tracing' ;;
    *) printf '%s' "$1" ;;
  esac
}

langfuse_installed() {
  case " $HOSTS " in *" claude "*)
    case "$(claude plugin list --json 2>/dev/null || true)" in *"\"$LANGFUSE_PLUGIN@$MARKETPLACE\""*) return 0 ;; esac ;;
  esac
  case " $HOSTS " in *" codex "*)
    case "$(codex plugin list --json 2>/dev/null || true)" in *"\"$(codex_name "$LANGFUSE_PLUGIN")@$MARKETPLACE\""*) return 0 ;; esac ;;
  esac
  return 1
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
    if [ "$plugin" = "$LANGFUSE_PLUGIN" ] && ! have npm && [ "$DRY_RUN" -eq 0 ]; then
      warn "skipping $(codex_name "$plugin")@$MARKETPLACE: Codex installs it with npm, which is not on PATH"
      continue
    fi
    run codex plugin add "$(codex_name "$plugin")@$MARKETPLACE"
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

# The same text is in install.ps1; install.test.mjs keeps the two equal.
langfuse_check_js() {
  cat <<'JS'
// Exits 0 when the Langfuse server accepts the key pair, 1 when it refuses it and 2 when it cannot
// be reached. The keys come in the environment, so they never appear on a command line.
const { LANGFUSE_BASE_URL: url, LANGFUSE_PUBLIC_KEY: publicKey, LANGFUSE_SECRET_KEY: secretKey } = process.env;
const auth = Buffer.from(`${publicKey}:${secretKey}`).toString("base64");
fetch(`${url}/api/public/projects`, { headers: { Authorization: `Basic ${auth}` }, signal: AbortSignal.timeout(15000) }).then(
  (response) => {
    console.log(`HTTP ${response.status}`);
    process.exit(response.ok ? 0 : 1);
  },
  (error) => {
    console.log(error.cause?.code ?? error.name);
    process.exit(2);
  },
);
JS
}

# The same text is in install.ps1; install.test.mjs keeps the two equal.
sessionend_timeout_js() {
  cat <<'JS'
// Sets CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS under "env" in Claude Code's settings file, keeping
// everything else in it. Without PURISEV_WRITE it only checks. Exits 0 when the value is (to be) set,
// 3 when the file has one already, which it prints, and 1 when the file is not a JSON object.
const fs = require("fs");
const path = require("path");
const { PURISEV_SETTINGS: file, PURISEV_TIMEOUT_MS: timeout, PURISEV_WRITE: write } = process.env;
const name = "CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS";
const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
let settings = {};
let mode = 0o600;
try {
  settings = JSON.parse(fs.readFileSync(file, "utf-8").replace(/^\uFEFF/, ""));
  mode = fs.statSync(file).mode & 0o777;
} catch (error) {
  if (error.code !== "ENOENT") {
    console.log(error.message);
    process.exit(1);
  }
}
if (!isObject(settings) || (settings.env !== undefined && !isObject(settings.env))) {
  console.log(`${file} or its "env" is not a JSON object`);
  process.exit(1);
}
if (settings.env?.[name] !== undefined) {
  console.log(settings.env[name]);
  process.exit(3);
}
if (write) {
  settings.env = { ...settings.env, [name]: timeout };
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temp, `${JSON.stringify(settings, null, 2)}\n`, { mode });
  fs.renameSync(temp, file);
}
JS
}

# Claude Code gives SessionEnd hooks a second and a half at exit unless told otherwise, and stops the
# Langfuse hook before it sends the session's last turn.
claude_sessionend_timeout() {
  on_host claude || return 0
  settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
  name=CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS
  if [ -n "${CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS:-}" ]; then
    say "  $name is set in this environment; leaving $settings as it is"
    return 0
  fi
  manual="add \"env\": {\"$name\": \"$SESSIONEND_TIMEOUT_MS\"} to $settings, or Claude Code stops the Langfuse hook at exit and the last turn of each session never reaches Langfuse"
  if ! node_is_usable; then
    warn "$settings cannot be edited without node; $manual"
    return 0
  fi
  status=0
  found=$(PURISEV_SETTINGS="$settings" node -e "$(sessionend_timeout_js)") || status=$?
  case "$status" in
    0) ;;
    3) say "  $settings sets $name to $found; leaving it as it is"; return 0 ;;
    *) warn "$settings cannot be read as JSON ($found); $manual"; return 0 ;;
  esac
  if ! confirm "Let Claude Code wait up to $((SESSIONEND_TIMEOUT_MS / 1000)) s at exit for the Langfuse hook ($name in $settings)?"; then
    warn "not editing $settings; $manual"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would set $name to $SESSIONEND_TIMEOUT_MS in $settings"
    return 0
  fi
  if PURISEV_SETTINGS="$settings" PURISEV_TIMEOUT_MS="$SESSIONEND_TIMEOUT_MS" PURISEV_WRITE=1 node -e "$(sessionend_timeout_js)" >/dev/null; then
    say "  set $name to $SESSIONEND_TIMEOUT_MS in $settings"
  else
    warn "could not write $settings; $manual"
  fi
}

check_codex_hooks() {
  on_host codex || return 0
  if codex features list 2>/dev/null | grep -q '^hooks[[:space:]].*[[:space:]]false$'; then
    warn "hooks are off in Codex; set hooks = true under [features] in ~/.codex/config.toml"
  fi
}

claude_has_langfuse_keys() {
  claude plugin configure "$LANGFUSE_PLUGIN@$MARKETPLACE" --json 2>/dev/null | tr -d ' \t\r\n' | grep -q '"configured":\[[^]]*"LANGFUSE_SECRET_KEY"'
}

save_langfuse_keys() {
  for host in $1; do
    case "$host" in
      claude)
        values=$(printf '{"LANGFUSE_BASE_URL":"%s","LANGFUSE_PUBLIC_KEY":"%s","LANGFUSE_SECRET_KEY":"%s"}' \
          "$(json_string "$url")" "$(json_string "$public_key")" "$(json_string "$secret_key")")
        say "  claude plugin configure $LANGFUSE_PLUGIN@$MARKETPLACE --values-stdin"
        printf '%s' "$values" | claude plugin configure "$LANGFUSE_PLUGIN@$MARKETPLACE" --values-stdin \
          || warn "Claude Code did not save the Langfuse keys; run /plugin configure $LANGFUSE_PLUGIN@$MARKETPLACE in it" ;;
      codex)
        mkdir -p "$(dirname "$codex_conf")"
        ( umask 077; printf '{\n  "enabled": true,\n  "base_url": "%s",\n  "public_key": "%s",\n  "secret_key": "%s"\n}\n' \
          "$(json_string "$url")" "$(json_string "$public_key")" "$(json_string "$secret_key")" >"$codex_conf" )
        chmod 600 "$codex_conf"
        say "  wrote $codex_conf (mode 600)" ;;
    esac
  done
}

setup_langfuse() {
  case " $PLUGINS " in *" $LANGFUSE_PLUGIN "*) ;; *) return 0 ;; esac
  step "Langfuse"
  claude_sessionend_timeout
  check_codex_hooks
  [ "$CONFIGURE" -eq 1 ] || return 0

  codex_conf="${CODEX_HOME:-$HOME/.codex}/langfuse.json"
  needs=""
  for host in $HOSTS; do
    case "$host" in
      claude)
        if claude_has_langfuse_keys; then say "  Claude Code has the Langfuse keys; leaving them as they are"
        else needs="$needs claude"
        fi ;;
      codex)
        if [ -f "$codex_conf" ]; then say "  $codex_conf exists; leaving it as it is"
        else needs="$needs codex"
        fi ;;
    esac
  done
  [ -n "$needs" ] || return 0

  url="${LANGFUSE_BASE_URL:-}"
  public_key="${LANGFUSE_PUBLIC_KEY:-}"
  secret_key="${LANGFUSE_SECRET_KEY:-}"
  if [ -z "$url" ] || [ -z "$public_key" ] || [ -z "$secret_key" ]; then
    if ! can_ask; then
      say "  No Langfuse keys saved. Set LANGFUSE_BASE_URL, LANGFUSE_PUBLIC_KEY and LANGFUSE_SECRET_KEY and run the installer again with --langfuse."
      return 0
    fi
    [ -n "$url" ] || url=$(ask "  Langfuse server URL (for example https://langfuse.example.com)")
    [ -n "$public_key" ] || public_key=$(ask "  Public key of the Langfuse project (pk-lf-...)")
    [ -n "$secret_key" ] || secret_key=$(ask_secret "  Secret key (sk-lf-...; input is hidden)")
    if [ -z "$url" ] || [ -z "$public_key" ] || [ -z "$secret_key" ]; then
      warn "the URL and both keys are needed; no Langfuse keys saved"
      return 0
    fi
  fi
  url=${url%/}

  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would check the keys against $url and save them for:$needs"
    return 0
  fi
  if node_is_usable; then
    if verdict=$(LANGFUSE_BASE_URL="$url" LANGFUSE_PUBLIC_KEY="$public_key" LANGFUSE_SECRET_KEY="$secret_key" node -e "$(langfuse_check_js)"); then
      say "  $url accepts the keys"
    else
      warn "$url did not accept the keys ($verdict); no Langfuse keys saved"
      return 0
    fi
  else
    warn "the keys cannot be checked without node; saving them unchecked"
  fi
  save_langfuse_keys "$needs"
}

finish() {
  step "Done"
  say "  Restart the hosts so they load the plugins."
  if [ "${CODEX_INSTALLED:-0}" -eq 1 ]; then
    say "  Codex: run /hooks once and approve the hooks the plugins bring."
  fi
  say "  Check the setup with the ov-memory-doctor skill; it names anything still missing."
  say "  Documentation: https://ai-plugins.purisev.com"
}

main() {
  parse_args "$@"
  PLUGINS="${WANT_PLUGINS:-$ALL_PLUGINS}"
  STAMP=$(date +%Y%m%d-%H%M%S)
  if [ "$DRY_RUN" -eq 1 ]; then say "Dry run: nothing will be changed."; fi

  detect_hosts
  if [ "$WANT_LANGFUSE" -eq 1 ] || { [ -z "$WANT_PLUGINS" ] && langfuse_installed; }; then
    case " $PLUGINS " in *" $LANGFUSE_PLUGIN "*) ;; *) PLUGINS="$PLUGINS $LANGFUSE_PLUGIN" ;; esac
  fi
  check_tools
  for host in $HOSTS; do
    case "$host" in
      claude) install_into_claude ;;
      codex) install_into_codex ;;
    esac
    handle_duplicates "$host"
  done
  configure_connection
  setup_langfuse
  finish
}

main "$@"
