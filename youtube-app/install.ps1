# Installs "YouTube" as a Windows app: a dedicated Firefox profile with
# uBlock Origin, no browser toolbars, and YouTube's app layout.
#
#   .\install.ps1                 mobile-app layout (m.youtube.com) in a window
#   .\install.ps1 -Layout tv      TV-app layout (youtube.com/tv), fullscreen
param(
  [ValidateSet('mobile', 'tv')]
  [string]$Layout = 'mobile'
)
$ErrorActionPreference = 'Stop'

$UboUrl = 'https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi'
$UboId = 'uBlock0@raymondhill.net'
$AppHome = Join-Path $env:LOCALAPPDATA 'YouTubeApp'
$ProfileDir = Join-Path $AppHome 'profile'
$Src = $PSScriptRoot

# --- Find Firefox -----------------------------------------------------------

$candidates = @()
foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\firefox.exe',
                 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\firefox.exe') {
  try { $candidates += (Get-ItemProperty $key).'(default)' } catch {}
}
$candidates += "$env:ProgramFiles\Mozilla Firefox\firefox.exe",
               "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe",
               "$env:LOCALAPPDATA\Mozilla Firefox\firefox.exe"
$Firefox = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $Firefox) { throw 'Firefox not found. Install Firefox first.' }

$major = 140
try { $major = [int](((Get-Item $Firefox).VersionInfo.ProductVersion -split '\.')[0]) } catch {}
Write-Host "Using Firefox $major`: $Firefox"

# --- Layout -----------------------------------------------------------------

if ($Layout -eq 'tv') {
  $Url = 'https://www.youtube.com/tv'
  $Ua = 'Mozilla/5.0 (PS4; Leanback Shell) Gecko/20100101 Firefox/65.0 LeanbackShell/01.00.01.75 Sony PS4/ (PS4, , no, CH)'
  $ExtraArgs = '--kiosk '
} else {
  $Url = 'https://m.youtube.com/'
  $Ua = "Mozilla/5.0 (Android 14; Mobile; rv:$major.0) Gecko/$major.0 Firefox/$major.0"
  $ExtraArgs = ''
}

# --- Profile ----------------------------------------------------------------

New-Item -ItemType Directory -Force -Path (Join-Path $ProfileDir 'chrome'), (Join-Path $ProfileDir 'extensions') | Out-Null

$userJs = (Get-Content -Raw (Join-Path $Src 'profile\user.js')).Replace('__UA__', $Ua).Replace('__URL__', $Url)
[IO.File]::WriteAllText((Join-Path $ProfileDir 'user.js'), $userJs)
Copy-Item (Join-Path $Src 'profile\chrome\*.css') (Join-Path $ProfileDir 'chrome') -Force
# Only seed the window size once, so later resizing is remembered.
if (-not (Test-Path (Join-Path $ProfileDir 'xulstore.json'))) {
  Copy-Item (Join-Path $Src 'profile\xulstore.json') $ProfileDir
}

Write-Host 'Downloading uBlock Origin...'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$xpi = Join-Path $ProfileDir "extensions\$UboId.xpi"
Invoke-WebRequest -UseBasicParsing -Uri $UboUrl -OutFile "$xpi.part"
Move-Item -Force "$xpi.part" $xpi

# --- Shortcuts --------------------------------------------------------------

Copy-Item (Join-Path $Src 'icon.ico') $AppHome -Force
$shell = New-Object -ComObject WScript.Shell
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
foreach ($dir in $startMenu, [Environment]::GetFolderPath('Desktop')) {
  $lnk = $shell.CreateShortcut((Join-Path $dir 'YouTube.lnk'))
  $lnk.TargetPath = $Firefox
  $lnk.Arguments = "--profile `"$ProfileDir`" $ExtraArgs`"$Url`""
  $lnk.WorkingDirectory = $AppHome
  $lnk.IconLocation = Join-Path $AppHome 'icon.ico'
  $lnk.Description = 'YouTube in Firefox with uBlock Origin'
  $lnk.Save()
}
Write-Host 'Installed: "YouTube" in the Start menu and on the desktop.'
