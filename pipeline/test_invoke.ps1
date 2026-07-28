$ErrorActionPreference = 'Stop'
$pipelineRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$invoke = Join-Path $pipelineRoot 'invoke.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) ("claude-orchestrate-invoke-" + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $work 'repo'
$before = (Get-Location).Path

New-Item -ItemType Directory -Path $repo -Force | Out-Null
try {
    Set-Content -LiteralPath (Join-Path $repo 'package.json') -Value '{}'
    & $invoke detect -Repo $repo
    if ($LASTEXITCODE -ne 0) { throw "invoke.ps1 returned $LASTEXITCODE" }
    if (-not (Test-Path -LiteralPath (Join-Path $repo '.pipeline\toolchain.json'))) {
        throw 'detect did not run in -Repo'
    }
    if ((Get-Location).Path -ne $before) { throw 'caller working directory changed' }
}
finally {
    if ((Test-Path -LiteralPath $work) -and $work.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}

Write-Output 'invoke -Repo test passed'
