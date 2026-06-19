[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Message,

    [Parameter(Mandatory = $true)]
    [string[]]$Paths
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $repoRoot

$currentBranch = (git branch --show-current).Trim()
if ($currentBranch -ne 'main') {
    throw "This script only publishes from 'main'. Current branch is '$currentBranch'."
}

foreach ($path in $Paths) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Path not found: $path"
    }
}

git add -- @Paths

$stagedNames = git diff --cached --name-only
if (-not $stagedNames) {
    throw "No staged changes found after git add."
}

git commit -m $Message
git push origin main

Write-Host "Published commit on main with message: $Message"
