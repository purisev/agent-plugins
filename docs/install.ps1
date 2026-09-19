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
  [ValidateSet('openviking-memory', 'ov-wiki')]
  [string[]]$Plugin = @(),
  [switch]$NoConfig,
  [switch]$Yes,
  [switch]$DryRun
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$Marketplace = 'purisev'
$MarketplaceRepo = 'purisev/agent-plugins'
$AllPlugins = @('openviking-memory', 'ov-wiki')
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
    Say '  openviking-memory runs its hooks and MCP server with the bare node command.'
    if (Confirm-Step "Install the official Node.js $NodeLine build under your user profile (no administrator rights needed)?") {
      Install-Node
    } else {
      Warn "continuing without a usable node; openviking-memory stays inactive until Node.js $MinNodeMajor or newer is on PATH"
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
  foreach ($name in $Plugins) { Invoke-Tool codex plugin add "$name@$Marketplace" }
  $script:CodexInstalled = $true
}

function Initialize-Connection([string[]]$Plugins) {
  if ($NoConfig -or ($Plugins -notcontains 'openviking-memory')) { return }
  $conf = if ($env:OPENVIKING_CLI_CONFIG_FILE) { $env:OPENVIKING_CLI_CONFIG_FILE } else { Join-Path $HOME '.openviking/ovcli.conf' }

  Step 'Connection to OpenViking'
  if (Test-Path $conf) { Say "  $conf exists; leaving it as it is"; return }
  if ($env:OPENVIKING_URL -or $env:OPENVIKING_BASE_URL) { Say "  OPENVIKING_URL is set in this environment; not creating $conf"; return }
  if (-not (CanAsk)) {
    Say "  $conf does not exist. Create it with `"url`" and `"api_key`", readable by you only,"
    Say '  or answer the connection prompts when Claude Code enables the plugin.'
    return
  }
  if (-not (Confirm-Step "Create $conf now? Claude Code and Codex both read it.")) { return }

  $url = Read-Host '  OpenViking server URL (API root, for example https://openviking.example.com)'
  if (-not $url) { Warn "no URL given; not creating $conf"; return }
  $secure = Read-Host '  API key (a user or admin key; input is hidden)' -AsSecureString
  $key = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
  if ($DryRun) { Say "  would write $conf, readable by you only"; return }

  New-Item -ItemType Directory -Path (Split-Path $conf) -Force | Out-Null
  # No byte-order mark: the plugins parse this file with JSON.parse, which rejects one.
  $json = [ordered]@{ url = $url; api_key = $key } | ConvertTo-Json
  [IO.File]::WriteAllText($conf, "$json`n", (New-Object Text.UTF8Encoding $false))
  if (OnWindows) { & icacls $conf /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null }
  else { & chmod 600 $conf }
  Say "  wrote $conf, readable by you only"
}

function Main {
  $plugins = if ($Plugin.Count -gt 0) { $Plugin } else { $AllPlugins }
  if ($DryRun) { Say 'Dry run: nothing will be changed.' }

  Test-Toolchain
  foreach ($name in (Get-AgentHost)) {
    if ($name -eq 'claude') { Install-IntoClaude $plugins } else { Install-IntoCodex $plugins }
  }
  Initialize-Connection $plugins

  Step 'Done'
  Say '  Restart the hosts so they load the plugins.'
  if ($script:CodexInstalled) { Say '  Codex: run /hooks once and approve the hooks openviking-memory brings.' }
  Say '  Check the setup with the ov-memory-doctor skill; it names anything still missing.'
  Say '  Documentation: https://ai-plugins.purisev.com'
}

Main
