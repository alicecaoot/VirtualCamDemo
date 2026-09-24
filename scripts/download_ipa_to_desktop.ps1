# Download latest VirtualCamDemo-ipa artifact from GitHub Actions to Desktop.
# Usage:
#   $env:GH_TOKEN = "ghp_...."   # need repo scope
#   .\scripts\download_ipa_to_desktop.ps1 -Owner YOU -Repo MyFirstTweak
param(
  [Parameter(Mandatory = $true)][string]$Owner,
  [Parameter(Mandatory = $true)][string]$Repo,
  [string]$Desktop = [Environment]::GetFolderPath("Desktop"),
  [string]$ArtifactName = "VirtualCamDemo-ipa"
)

$ErrorActionPreference = "Stop"
$gh = $env:GH_TOKEN
if (-not $gh) { $gh = $env:GITHUB_TOKEN }
if (-not $gh) { throw "Set GH_TOKEN or GITHUB_TOKEN first" }

$headers = @{
  Authorization = "Bearer $gh"
  Accept        = "application/vnd.github+json"
  "X-GitHub-Api-Version" = "2022-11-28"
  "User-Agent"  = "MyFirstTweak-ipa-downloader"
}

$runs = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$Owner/$Repo/actions/runs?per_page=10"
$run = $runs.workflow_runs | Where-Object { $_.name -match "Build VirtualCamDemo IPA" -and $_.status -eq "completed" -and $_.conclusion -eq "success" } | Select-Object -First 1
if (-not $run) {
  $run = $runs.workflow_runs | Where-Object { $_.status -eq "completed" -and $_.conclusion -eq "success" } | Select-Object -First 1
}
if (-not $run) { throw "No successful workflow run found. Push + wait for CI." }

Write-Host "Using run $($run.id) $($run.html_url)"
$arts = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$Owner/$Repo/actions/runs/$($run.id)/artifacts"
$art = $arts.artifacts | Where-Object { $_.name -eq $ArtifactName } | Select-Object -First 1
if (-not $art) { throw "Artifact $ArtifactName not found on run $($run.id)" }

$zipPath = Join-Path $env:TEMP "VirtualCamDemo-ipa-art.zip"
$extract = Join-Path $env:TEMP "VirtualCamDemo-ipa-art"
Invoke-WebRequest -Headers $headers -Uri $art.archive_download_url -OutFile $zipPath
if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
Expand-Archive $zipPath $extract -Force

$ipa = Get-ChildItem $extract -Recurse -Filter "*.ipa" | Select-Object -First 1
if (-not $ipa) { throw "No .ipa inside artifact" }

$dest = Join-Path $Desktop "VirtualCamDemo.ipa"
Copy-Item $ipa.FullName $dest -Force
Write-Host "OK -> $dest ($((Get-Item $dest).Length) bytes)"
Get-Item $dest | Format-List FullName, Length, LastWriteTime
