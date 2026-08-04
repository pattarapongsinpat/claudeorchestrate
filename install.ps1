$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$runtime = Join-Path $HOME '.claudeorchestrate'
$legacyRuntime = Join-Path $HOME '.claudeochestrate'
$claudeHome = Join-Path $HOME '.claude'

function Resolve-ExistingPath([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.LinkType -eq 'Junction') {
        return [System.IO.Path]::GetFullPath([string]$item.Target[0])
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Ensure-Junction([string]$Path, [string]$Target) {
    $resolvedTarget = (Resolve-Path -LiteralPath $Target).Path
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        $existingTarget = if ($item.LinkType -eq 'Junction') {
            [System.IO.Path]::GetFullPath([string]$item.Target[0])
        } else {
            (Resolve-Path -LiteralPath $Path).Path
        }
        if ($existingTarget -ne $resolvedTarget) {
            throw "Path already exists and points elsewhere: $Path"
        }
        return
    }
    New-Item -ItemType Junction -Path $Path -Target $resolvedTarget | Out-Null
}

function Remove-LegacyJunction([string]$Path, [string]$LegacyTarget) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.LinkType -ne 'Junction') { return }
    $existingTarget = [System.IO.Path]::GetFullPath([string]$item.Target[0])
    $expectedLegacyTarget = [System.IO.Path]::GetFullPath($LegacyTarget)
    if ($existingTarget -eq $expectedLegacyTarget) {
        [System.IO.Directory]::Delete($Path)
    }
}

if ($repoRoot -ne (Resolve-ExistingPath $runtime)) {
    if (Test-Path -LiteralPath $runtime) {
        throw "Runtime path already exists and points elsewhere: $runtime"
    }
    New-Item -ItemType Junction -Path $runtime -Target $repoRoot | Out-Null
}

New-Item -ItemType Directory -Path $claudeHome -Force | Out-Null

$skillsDir = Join-Path $claudeHome 'skills'
New-Item -ItemType Directory -Path $skillsDir -Force | Out-Null
Remove-LegacyJunction (Join-Path $skillsDir 'build') (Join-Path $legacyRuntime '.claude\skills\build')
Ensure-Junction (Join-Path $skillsDir 'build') (Join-Path $runtime '.claude\skills\build')

$commandsDir = Join-Path $claudeHome 'commands'
Remove-LegacyJunction $commandsDir (Join-Path $legacyRuntime '.claude\commands')
if (-not (Test-Path -LiteralPath $commandsDir)) {
    New-Item -ItemType Junction -Path $commandsDir -Target (Join-Path $runtime '.claude\commands') | Out-Null
} else {
    Get-ChildItem -LiteralPath (Join-Path $runtime '.claude\commands') -Filter '*.md' | ForEach-Object {
        $destination = Join-Path $commandsDir $_.Name
        if (Test-Path -LiteralPath $destination) {
            $sourceHash = (Get-FileHash -LiteralPath $_.FullName).Hash
            $destinationHash = (Get-FileHash -LiteralPath $destination).Hash
            if ($sourceHash -ne $destinationHash) {
                throw "Global command conflicts with this project: $destination"
            }
        } else {
            Copy-Item -LiteralPath $_.FullName -Destination $destination
        }
    }
}

$memory = Join-Path $claudeHome 'CLAUDE.md'
$marker = '<!-- claudeorchestrate:global -->'
$memoryText = if (Test-Path -LiteralPath $memory) { Get-Content -Raw -LiteralPath $memory } else { '' }
$legacyMarker = '<!-- claudeochestrate:global -->'
$legacyPath = ($legacyRuntime -replace '\\', '/')
$runtimePath = ($runtime -replace '\\', '/')
if ($memoryText.Contains($legacyMarker) -or $memoryText.Contains($legacyPath)) {
    $memoryText = $memoryText.Replace($legacyMarker, $marker).Replace($legacyPath, $runtimePath)
    Set-Content -LiteralPath $memory -Value $memoryText -Encoding utf8
}
$importPath = ($runtime -replace '\\', '/') + '/PIPELINE.md'
if (-not $memoryText.Contains($marker) -and -not $memoryText.Contains("@$importPath")) {
    $routing = "Write ordinary changes directly; that is the default. Save ``/build <request>`` for work that is large, risky, or undecided, and ``/campaign <request>`` for work too large for one plan. The escalation conditions are in the build skill."
    $block = "`n`n$marker`n## Autonomous development workflow`n`nUse the globally installed build skill for software changes in Git projects.`n$routing`n`n@$importPath`n"
    Add-Content -LiteralPath $memory -Value $block -Encoding utf8
}

$envFile = Join-Path $runtime '.env'
if (-not (Test-Path -LiteralPath $envFile)) {
    Copy-Item -LiteralPath (Join-Path $runtime '.env.example') -Destination $envFile
}

if (Get-Command winget -ErrorAction SilentlyContinue) {
    $wingetPackages = @{
        jq = 'jqlang.jq'
        rg = 'BurntSushi.ripgrep.MSVC'
    }
    foreach ($entry in $wingetPackages.GetEnumerator()) {
        if (-not (Get-Command $entry.Key -ErrorAction SilentlyContinue)) {
            winget install --id $entry.Value --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
        }
    }
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
}

$missing = @()
foreach ($command in @('git', 'jq', 'curl', 'rg')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { $missing += $command }
}
$gitBash = 'C:\Program Files\Git\bin\bash.exe'
if (-not (Test-Path -LiteralPath $gitBash)) { $missing += 'Git Bash' }

if ($missing.Count -gt 0) {
    Write-Warning "Install missing prerequisites: $($missing -join ', ')"
}

Write-Output "Installed Claude orchestration from $repoRoot"
Write-Output "Set DEEPSEEK_API_KEY in $envFile, then restart Claude Code."
