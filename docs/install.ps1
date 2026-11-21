# Installer for the purisev agent plugins: https://ai-plugins.purisev.com
#
#   irm https://ai-plugins.purisev.com/install.ps1 | iex
#   & ([scriptblock]::Create((irm https://ai-plugins.purisev.com/install.ps1))) -DryRun
#
# Windows counterpart of install.sh, with the same steps and options. Everything
# lives in functions and Main runs on the last line, so a download that stops
# halfway executes nothing.

param(
  [ValidateSet('claude', 'codex')]
  [string[]]$AgentHost = @(),
  [ValidateSet('openviking-memory', 'ov-wiki', 'humanizer', 'ponytail', 'infra', 'playwright', 'langfuse-observability')]
  [string[]]$Plugin = @(),
  [switch]$Langfuse,
  [switch]$NoConfig,
  [switch]$RemoveDuplicates,
  [switch]$Yes,
  [switch]$DryRun
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$Marketplace = 'purisev'
$MarketplaceRepo = 'purisev/agent-plugins'
$AllPlugins = @('openviking-memory', 'ov-wiki', 'humanizer', 'ponytail', 'infra', 'playwright')
# Installed only on request, or when a host already has them.
$OptionalPlugins = @('langfuse-observability')
$LangfusePlugin = 'langfuse-observability'
$MinNodeMajor = 18
$NodeLine = 'v22'
$NodeDist = "https://nodejs.org/dist/latest-$NodeLine.x"
$script:CodexInstalled = $false

function Say([string]$Text) { Write-Host $Text }
function Step([string]$Text) { Write-Host ''; Write-Host "==> $Text" }
function Warn([string]$Text) { Write-Warning $Text }
function Have([string]$Name) { return [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# Windows PowerShell 5.1 has no $IsWindows and runs only on Windows.
function OnWindows { return (-not (Test-Path variable:IsWindows)) -or $IsWindows }

function CanAsk { return (-not $Yes) -and [Environment]::UserInteractive -and (-not [Console]::IsInputRedirected) }

function Confirm-Step([string]$Question) {
  if ($Yes) { return $true }
  if (-not (CanAsk)) { return $false }
  $reply = Read-Host "$Question [y/N]"
  return $reply -match '^(y|yes)$'
}

function Invoke-Tool {
  $display = $args -join ' '
  if ($DryRun) { Say "  would run: $display"; return }
  Say "  $display"
  $command = $args[0]
  $rest = @($args | Select-Object -Skip 1)
  & $command @rest
  if ($LASTEXITCODE -ne 0) { throw "$display exited with code $LASTEXITCODE" }
}

function Get-NodeMajor {
  if (-not (Have 'node')) { return 0 }
  try { return [int]((& node -p 'process.versions.node.split(".")[0]') | Select-Object -First 1) } catch { return 0 }
}

# The official build, checksum-verified, unpacked under the user's profile. No
# administrator rights and no package manager, so it cannot disturb a system Node.js.
function Install-Node {
  if (-not (OnWindows)) { throw 'this script installs Node.js on Windows only; on Linux and macOS use install.sh' }
  $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
  $target = Join-Path $env:LOCALAPPDATA 'Programs\nodejs'

  if ($DryRun) {
    Say "  would download the latest Node.js $NodeLine for win-$arch from $NodeDist"
    Say "  would verify it against SHASUMS256.txt and unpack it under $target"
    Say '  would add that directory to your user PATH'
    return
  }

  $work = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
  New-Item -ItemType Directory -Path $work | Out-Null
  try {
    $sums = (Invoke-WebRequest -UseBasicParsing "$NodeDist/SHASUMS256.txt").Content -split "`n"
    $line = $sums | Where-Object { $_ -match "^[0-9a-f]+\s+node-v[0-9.]+-win-$arch\.zip\s*$" } | Select-Object -First 1
    if (-not $line) { throw "no Node.js $NodeLine archive for win-$arch is listed at $NodeDist" }
    $expected, $archive = ($line.Trim() -split '\s+')
    Say "  downloading $NodeDist/$archive"
    $zip = Join-Path $work $archive
    Invoke-WebRequest -UseBasicParsing "$NodeDist/$archive" -OutFile $zip
    $actual = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
    if ($actual -ne $expected.ToLowerInvariant()) { throw "checksum mismatch for $archive; nothing was installed" }

    Expand-Archive -Path $zip -DestinationPath $work -Force
    $unpacked = Join-Path $work ([IO.Path]::GetFileNameWithoutExtension($archive))
    if (Test-Path $target) { Remove-Item -Recurse -Force $target }
    New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
    Move-Item $unpacked $target
  } finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
  }

  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (($userPath -split ';') -notcontains $target) {
    $entries = @($target, $userPath) | Where-Object { $_ }
    [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')
    Say "  added $target to your user PATH; new terminals pick it up"
  }
  $env:Path = "$target;$env:Path"
  Say "  installed $(& (Join-Path $target 'node.exe') --version) under $target"
}

function Test-Toolchain {
  Step 'Checking tools'
  if (-not (Have 'git')) { throw 'git is not on PATH; the hosts clone plugins with it' }
  Say "  git: $(& git --version)"

  $major = Get-NodeMajor
  if ($major -ge $MinNodeMajor) {
    Say "  node: $(& node --version)"
  } else {
    if ($major -gt 0) { Say "  node: $(& node --version) is older than $MinNodeMajor" } else { Say '  node: not found' }
    Say '  openviking-memory and ponytail run their hooks with the bare node command.'
    if (Confirm-Step "Install the official Node.js $NodeLine build under your user profile (no administrator rights needed)?") {
      Install-Node
    } else {
      Warn "continuing without a usable node; openviking-memory stays inactive until Node.js $MinNodeMajor or newer is on PATH, and ponytail's hooks fail"
    }
  }

  if (Have 'uv') { Say "  uv: $(& uv --version)" }
  elseif (Have 'python3') { Say "  python3: $(& python3 --version) (ov-wiki's optional offline helpers also need PyYAML; uv resolves it by itself)" }
  elseif (Have 'python') { Say "  python: $(& python --version) (ov-wiki's optional offline helpers also need PyYAML; uv resolves it by itself)" }
  else { Say "  neither uv nor python: ov-wiki works without its optional offline helpers" }
}

function Get-AgentHost {
  if ($AgentHost.Count -gt 0) {
    foreach ($name in $AgentHost) { if (-not (Have $name)) { throw "$name was requested but is not on PATH" } }
    return $AgentHost
  }
  $found = @('claude', 'codex' | Where-Object { Have $_ })
  if ($found.Count -eq 0) { throw 'neither claude nor codex is on PATH; install Claude Code or Codex first' }
  return $found
}

# Codex installs a plugin only under the name in its manifest, and Langfuse's Codex plugin is called tracing.
function Get-CodexName([string]$Name) {
  if ($Name -eq $LangfusePlugin) { return 'tracing' }
  return $Name
}

function Test-LangfuseInstalled([string[]]$Hosts) {
  if ($Hosts -contains 'claude') {
    $installed = (& claude plugin list --json 2>$null) -join "`n"
    if ($installed -like "*`"$LangfusePlugin@$Marketplace`"*") { return $true }
  }
  if ($Hosts -contains 'codex') {
    $installed = (& codex plugin list --json 2>$null) -join "`n"
    if ($installed -like "*`"$(Get-CodexName $LangfusePlugin)@$Marketplace`"*") { return $true }
  }
  return $false
}

function Install-IntoClaude([string[]]$Plugins) {
  Step 'Claude Code'
  $marketplaces = (& claude plugin marketplace list 2>$null) -join "`n"
  if ($marketplaces -like "*($MarketplaceRepo)*") { Invoke-Tool claude plugin marketplace update $Marketplace }
  else { Invoke-Tool claude plugin marketplace add $MarketplaceRepo }

  $installed = (& claude plugin list --json 2>$null) -join "`n"
  foreach ($name in $Plugins) {
    $id = "$name@$Marketplace"
    if ($installed -like "*`"$id`"*") { Invoke-Tool claude plugin update $id }
    else { Invoke-Tool claude plugin install $id }
  }
}

function Install-IntoCodex([string[]]$Plugins) {
  Step 'Codex'
  $marketplaces = @(& codex plugin marketplace list 2>$null)
  if ($marketplaces | Where-Object { $_ -match "^$Marketplace\s" }) { Invoke-Tool codex plugin marketplace upgrade $Marketplace }
  else { Invoke-Tool codex plugin marketplace add $MarketplaceRepo }
  foreach ($name in $Plugins) { Invoke-Tool codex plugin add "$(Get-CodexName $name)@$Marketplace" }
  $script:CodexInstalled = $true
}

# The same text is in install.sh; install.test.mjs keeps the two equal.
function Get-DuplicateFinder {
  return @'
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
'@
}

function Move-Skill([string]$Dir) {
  $dest = Join-Path ((Split-Path $Dir) + '.replaced') $script:Stamp
  if ($DryRun) { Say "  would move $Dir to $dest"; return }
  New-Item -ItemType Directory -Path $dest -Force | Out-Null
  Move-Item -LiteralPath $Dir -Destination $dest
  Say "  moved $Dir to $dest"
}

# Runs after the host's install, so the purisev copy is in place before another goes.
# A removal that fails is reported and the installer carries on.
function Resolve-Duplicate([string]$Name) {
  if ((Get-NodeMajor) -lt $MinNodeMajor) { Warn "not looking for duplicates in ${Name}: that needs node"; return }
  $js = Join-Path ([IO.Path]::GetTempPath()) "purisev-duplicates-$PID.js"
  [IO.File]::WriteAllText($js, (Get-DuplicateFinder), (New-Object Text.UTF8Encoding $false))
  $env:PURISEV_HOST = $Name
  try { $findings = @(& node $js 2>$null | Where-Object { $_ }) }
  catch { $findings = @() }
  finally {
    Remove-Item -LiteralPath $js -ErrorAction SilentlyContinue
    Remove-Item env:PURISEV_HOST -ErrorAction SilentlyContinue
  }
  if ($findings.Count -eq 0) { return }

  Step "Duplicates in $Name"
  if (-not $RemoveDuplicates) {
    foreach ($line in $findings) {
      $kind, $what, $owner = $line -split "`t"
      if ($kind -eq 'plugin') { Say "  ${what}: another copy of $owner" }
      elseif ($kind -eq 'skill') { Say "  ${what}: a loose copy of a skill $owner ships" }
    }
    Say '  Run the installer again with -RemoveDuplicates to remove them.'
    return
  }

  $removed = @()
  foreach ($line in $findings) {
    $kind, $what, $owner = $line -split "`t"
    switch ($kind) {
      'plugin' {
        if (Confirm-Step "Remove $what, another copy of ${owner}?") {
          $verb = if ($Name -eq 'claude') { 'uninstall' } else { 'remove' }
          try { Invoke-Tool $Name plugin $verb $what; $removed += $what }
          catch { Warn "could not remove ${what}; continuing" }
        } else { Say "  keeping $what" }
      }
      'marketplace' {
        # Removing a marketplace uninstalls everything from it, so only an emptied one goes.
        if (@($owner -split ',' | Where-Object { $removed -notcontains $_ }).Count -eq 0) {
          try { Invoke-Tool $Name plugin marketplace remove $what }
          catch { Warn "could not remove the marketplace ${what}; continuing" }
        }
      }
      'skill' {
        if (Confirm-Step "Move $what, a loose copy of a skill $owner ships, out of the way?") {
          try { Move-Skill $what }
          catch { Warn "could not move ${what}; continuing" }
        } else { Say "  keeping $what" }
      }
    }
  }
}

function Initialize-Connection([string[]]$Plugins) {
  if ($NoConfig -or ($Plugins -notcontains 'openviking-memory')) { return }
  $conf = if ($env:OPENVIKING_CLI_CONFIG_FILE) { $env:OPENVIKING_CLI_CONFIG_FILE } else { Join-Path $HOME '.openviking/ovcli.conf' }

  Step 'Connection to OpenViking'
  if (Test-Path $conf) { Say "  $conf exists; leaving it as it is"; return }
  if ($env:OPENVIKING_URL -or $env:OPENVIKING_BASE_URL) { Say "  OPENVIKING_URL is set in this environment; not creating $conf"; return }
  if (-not (CanAsk)) {
    Say "  $conf does not exist. Create it with `"url`" and `"api_key`", readable by you only."
    return
  }
  if (-not (Confirm-Step "Create $conf now? Claude Code and Codex both read it.")) { return }

  $url = Read-Host '  OpenViking server URL (API root, for example https://openviking.example.com)'
  if (-not $url) { Warn "no URL given; not creating $conf"; return }
  $secure = Read-Host '  API key (a user or admin key; input is hidden)' -AsSecureString
  $key = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
  if ($DryRun) { Say "  would write $conf, readable by you only"; return }

  $json = [ordered]@{ url = $url; api_key = $key } | ConvertTo-Json
  Write-PrivateFile $conf "$json`n"
  Say "  wrote $conf, readable by you only"
}

# The same text is in install.sh; install.test.mjs keeps the two equal.
function Get-LangfuseCheck {
  return @'
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
'@
}

function Test-LangfuseToolchain([string[]]$Hosts) {
  if (($Hosts -contains 'claude') -and -not (Have 'uv')) {
    if ((Have 'python3') -or (Have 'python')) {
      Warn "Claude Code runs the Langfuse hook with uv. Without it the hook needs Python 3.10 or newer as python3 with the langfuse package: pip install 'langfuse>=4.7,<5'"
    } else {
      Warn 'Claude Code runs the Langfuse hook with uv or python3, and neither is on PATH; no traces are sent until one is'
    }
  }
  if ($Hosts -contains 'codex') {
    if ((Get-NodeMajor) -lt 22) { Warn 'Codex runs the Langfuse hook with Node.js 22 or newer; no traces are sent from Codex until it is on PATH' }
    $features = @(& codex features list 2>$null)
    if ($features | Where-Object { $_ -match '^hooks\s.*\sfalse$' }) {
      Warn 'hooks are off in Codex; set hooks = true under [features] in ~/.codex/config.toml'
    }
  }
}

function Test-ClaudeLangfuseKey {
  $json = ((& claude plugin configure "$LangfusePlugin@$Marketplace" --json 2>$null) -join '') -replace '\s', ''
  return $json -match '"configured":\[[^\]]*"LANGFUSE_SECRET_KEY"'
}

function Write-PrivateFile([string]$Path, [string]$Text) {
  New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
  # No byte-order mark: the plugins parse these files with JSON.parse, which rejects one.
  [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
  if (OnWindows) { & icacls $Path /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null }
  else { & chmod 600 $Path }
}

function Initialize-Langfuse([string[]]$Plugins, [string[]]$Hosts) {
  if ($Plugins -notcontains $LangfusePlugin) { return }
  Step 'Langfuse'
  Test-LangfuseToolchain $Hosts
  if ($NoConfig) { return }

  $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
  $codexConf = Join-Path $codexHome 'langfuse.json'
  $needs = @()
  foreach ($name in $Hosts) {
    if ($name -eq 'claude') {
      if (Test-ClaudeLangfuseKey) { Say '  Claude Code has the Langfuse keys; leaving them as they are' } else { $needs += 'claude' }
    } elseif (Test-Path $codexConf) {
      Say "  $codexConf exists; leaving it as it is"
    } else {
      $needs += 'codex'
    }
  }
  if ($needs.Count -eq 0) { return }

  $url = $env:LANGFUSE_BASE_URL
  $publicKey = $env:LANGFUSE_PUBLIC_KEY
  $secretKey = $env:LANGFUSE_SECRET_KEY
  if (-not ($url -and $publicKey -and $secretKey)) {
    if (-not (CanAsk)) {
      Say '  No Langfuse keys saved. Set LANGFUSE_BASE_URL, LANGFUSE_PUBLIC_KEY and LANGFUSE_SECRET_KEY and run the installer again with -Langfuse.'
      return
    }
    if (-not $url) { $url = Read-Host '  Langfuse server URL (for example https://langfuse.example.com)' }
    if (-not $publicKey) { $publicKey = Read-Host '  Public key of the Langfuse project (pk-lf-...)' }
    if (-not $secretKey) {
      $secure = Read-Host '  Secret key (sk-lf-...; input is hidden)' -AsSecureString
      $secretKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    }
    if (-not ($url -and $publicKey -and $secretKey)) { Warn 'the URL and both keys are needed; no Langfuse keys saved'; return }
  }
  $url = $url.TrimEnd('/')

  if ($DryRun) { Say "  would check the keys against $url and save them for: $($needs -join ' ')"; return }
  if ((Get-NodeMajor) -ge $MinNodeMajor) {
    $saved = @{ url = $env:LANGFUSE_BASE_URL; publicKey = $env:LANGFUSE_PUBLIC_KEY; secretKey = $env:LANGFUSE_SECRET_KEY }
    $env:LANGFUSE_BASE_URL = $url
    $env:LANGFUSE_PUBLIC_KEY = $publicKey
    $env:LANGFUSE_SECRET_KEY = $secretKey
    # A file, not node -e: Windows PowerShell mangles the quotes in a native command's arguments.
    $js = Join-Path ([IO.Path]::GetTempPath()) "purisev-langfuse-$PID.js"
    [IO.File]::WriteAllText($js, (Get-LangfuseCheck), (New-Object Text.UTF8Encoding $false))
    try { $verdict = (& node $js) -join ' '; $accepted = $LASTEXITCODE -eq 0 }
    finally {
      Remove-Item -LiteralPath $js -ErrorAction SilentlyContinue
      $env:LANGFUSE_BASE_URL = $saved.url
      $env:LANGFUSE_PUBLIC_KEY = $saved.publicKey
      $env:LANGFUSE_SECRET_KEY = $saved.secretKey
    }
    if (-not $accepted) { Warn "$url did not accept the keys ($verdict); no Langfuse keys saved"; return }
    Say "  $url accepts the keys"
  } else {
    Warn 'the keys cannot be checked without node; saving them unchecked'
  }

  if ($needs -contains 'claude') {
    $values = [ordered]@{ LANGFUSE_BASE_URL = $url; LANGFUSE_PUBLIC_KEY = $publicKey; LANGFUSE_SECRET_KEY = $secretKey } | ConvertTo-Json -Compress
    Say "  claude plugin configure $LangfusePlugin@$Marketplace --values-stdin"
    $values | & claude plugin configure "$LangfusePlugin@$Marketplace" --values-stdin
    if ($LASTEXITCODE -ne 0) { Warn "Claude Code did not save the Langfuse keys; run /plugin configure $LangfusePlugin@$Marketplace in it" }
  }
  if ($needs -contains 'codex') {
    $json = [ordered]@{ enabled = $true; base_url = $url; public_key = $publicKey; secret_key = $secretKey } | ConvertTo-Json
    Write-PrivateFile $codexConf "$json`n"
    Say "  wrote $codexConf, readable by you only"
  }
}

function Main {
  $plugins = if ($Plugin.Count -gt 0) { $Plugin } else { $AllPlugins }
  if ($DryRun) { Say 'Dry run: nothing will be changed.' }
  $script:Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

  Test-Toolchain
  $hosts = @(Get-AgentHost)
  if ($Langfuse -or (($Plugin.Count -eq 0) -and (Test-LangfuseInstalled $hosts))) {
    if ($plugins -notcontains $LangfusePlugin) { $plugins = @($plugins) + $LangfusePlugin }
  }
  foreach ($name in $hosts) {
    if ($name -eq 'claude') { Install-IntoClaude $plugins } else { Install-IntoCodex $plugins }
    Resolve-Duplicate $name
  }
  Initialize-Connection $plugins
  Initialize-Langfuse $plugins $hosts

  Step 'Done'
  Say '  Restart the hosts so they load the plugins.'
  if ($script:CodexInstalled) { Say '  Codex: run /hooks once and approve the hooks the plugins bring.' }
  Say '  Check the setup with the ov-memory-doctor skill; it names anything still missing.'
  Say '  Documentation: https://ai-plugins.purisev.com'
}

Main
