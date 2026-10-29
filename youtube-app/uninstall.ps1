# Removes the YouTube app installed by install.ps1, including its Firefox profile.
$ErrorActionPreference = 'Stop'
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
foreach ($dir in $startMenu, [Environment]::GetFolderPath('Desktop')) {
  Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $dir 'YouTube.lnk')
}
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $env:LOCALAPPDATA 'YouTubeApp')
Write-Host 'YouTube app removed.'
