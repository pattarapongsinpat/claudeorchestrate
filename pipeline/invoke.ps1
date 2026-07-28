param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$Script,

    [string]$Repo = (Get-Location).Path,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$ScriptArgs
)

$ErrorActionPreference = 'Stop'
$pipelineRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$gitBash = 'C:\Program Files\Git\bin\bash.exe'

if (-not (Test-Path -LiteralPath $gitBash)) {
    throw "Git Bash was not found at $gitBash. Install Git for Windows."
}

$scriptPath = Join-Path $pipelineRoot "$Script.sh"
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Unknown pipeline script: $Script"
}

$repoPath = (Resolve-Path -LiteralPath $Repo).Path
if (-not (Test-Path -LiteralPath $repoPath -PathType Container)) {
    throw "Repository path is not a directory: $Repo"
}

$exitCode = 1
Push-Location -LiteralPath $repoPath
try {
    & $gitBash $scriptPath @ScriptArgs
    $exitCode = $LASTEXITCODE
}
finally {
    Pop-Location
}
exit $exitCode
