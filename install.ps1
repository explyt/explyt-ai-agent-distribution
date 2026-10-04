# Explyt AI Agent installer starter for Windows (spec 019, RQ-19).
#
#   irm https://raw.githubusercontent.com/explyt/explyt-ai-agent-distribution/main/install.ps1 | iex
#   & ([scriptblock]::Create((irm .../install.ps1))) -Channel dogfood
#
# It holds no installer logic. It downloads and verifies the Node version below, fetches the
# @explyt/ai-agent tarball with that Node's npm, unpacks only dist/install/installer.js and
# runs it; the installer does the rest and this script exits with its exit code. It needs no
# Node, npm or administrator rights.
param(
  [ValidateSet("stable", "dogfood")]
  [string]$Channel = "stable",
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$ExplytNodeVersion = "22.23.3"
$Package = "@explyt/ai-agent"

function Fail([string]$Message) {
  [Console]::Error.WriteLine("explyt installer: $Message")
  [Environment]::Exit(1)
}

# Windows PowerShell 5.1 may default to TLS 1.0; nodejs.org and npm need TLS 1.2 or later.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# The system bsdtar reads zip; a GNU tar that Git puts earlier on PATH does not.
$Tar = Join-Path $env:SystemRoot 'System32\tar.exe'
if (-not (Test-Path $Tar)) { Fail "the tool '$Tar' is required and was not found (Windows 10 1803 or later ships it)" }

$arch = $env:PROCESSOR_ARCHITECTURE
if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
if ($arch -ne "AMD64") { Fail "the platform win32-$arch is not supported (supported: linux-x64, darwin-x64, darwin-arm64, win32-x64)" }

$dataHome = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path $env:USERPROFILE ".local\share" }
$root = Join-Path $dataHome "explyt-ai-agent"
$nodeDir = Join-Path $root "node\$ExplytNodeVersion"
$nodeBin = Join-Path $nodeDir "node.exe"
$npmCli = Join-Path $nodeDir "node_modules\npm\bin\npm-cli.js"
$install = Join-Path $root "install"
$cache = Join-Path $install "npm-cache"
$userconfig = Join-Path $install "npmrc"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("explyt-install-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
  if (-not (Test-Path $nodeBin)) {
    $archive = "node-v$ExplytNodeVersion-win-x64.zip"
    $base = "https://nodejs.org/dist/v$ExplytNodeVersion"
    [Console]::Error.WriteLine("Downloading Node $ExplytNodeVersion")
    Invoke-WebRequest -UseBasicParsing -Uri "$base/SHASUMS256.txt" -OutFile (Join-Path $work "SHASUMS256.txt")
    Invoke-WebRequest -UseBasicParsing -Uri "$base/$archive" -OutFile (Join-Path $work $archive)
    $line = Get-Content (Join-Path $work "SHASUMS256.txt") | Where-Object { $_ -match "^([0-9a-f]{64})\s+$([regex]::Escape($archive))$" } | Select-Object -First 1
    if (-not $line) { Fail "SHASUMS256.txt lists no $archive" }
    $expected = ($line -split "\s+")[0]
    $actual = (Get-FileHash -Algorithm SHA256 -Path (Join-Path $work $archive)).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { Fail "the Node archive checksum does not match (SHA-256 $actual, expected $expected)" }
    $unpacked = Join-Path $work "node"
    New-Item -ItemType Directory -Force -Path $unpacked | Out-Null
    & $Tar -xf (Join-Path $work $archive) -C $unpacked --strip-components=1
    if ($LASTEXITCODE -ne 0) { Fail "cannot unpack $archive" }
    New-Item -ItemType Directory -Force -Path (Split-Path $nodeDir) | Out-Null
    if (Test-Path $nodeDir) { Remove-Item -Recurse -Force $nodeDir }
    Move-Item $unpacked $nodeDir
  }

  New-Item -ItemType Directory -Force -Path $install | Out-Null
  if (-not (Test-Path $userconfig)) { Set-Content -Path $userconfig -Value "registry=https://registry.npmjs.org/" -Encoding ascii }

  $tag = if ($Channel -eq "dogfood") { "dogfood" } else { "latest" }
  [Console]::Error.WriteLine("Fetching $Package@$tag")
  # A user's npm_config_* must not reach npm (RQ-21).
  Get-ChildItem env: | Where-Object { $_.Name -like "npm_config_*" } | ForEach-Object { Remove-Item "env:$($_.Name)" }
  $env:Path = "$nodeDir;$env:Path"
  Push-Location $work
  try {
    $tarball = & $nodeBin $npmCli pack "$Package@$tag" --cache $cache --userconfig $userconfig --silent
    if ($LASTEXITCODE -ne 0) { Fail "cannot fetch $Package@$tag" }
  } finally {
    Pop-Location
  }
  & $Tar -xzf (Join-Path $work ($tarball | Select-Object -Last 1)) -C $work package/dist/install/installer.js
  if ($LASTEXITCODE -ne 0) { Fail "the $Package tarball carries no installer" }

  $installerArgs = @("--channel", $Channel)
  if ($Json) { $installerArgs += "--json" }
  & $nodeBin (Join-Path $work "package\dist\install\installer.js") @installerArgs
  $code = $LASTEXITCODE
} finally {
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
# The installer's exit code is this script's exit code.
exit $code
