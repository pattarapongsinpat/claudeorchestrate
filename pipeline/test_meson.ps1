param([string]$MesonVersion = '1.9.1')
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('claudeorchestrate-meson-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $venv = Join-Path $testRoot 'python'
    & python -m venv $venv
    $python = Join-Path $venv 'Scripts\python.exe'
    & $python -m pip install --disable-pip-version-check --quiet "meson==$MesonVersion"
    if ($LASTEXITCODE -ne 0) { throw 'Meson installation failed.' }
    $env:Path = (Join-Path $venv 'Scripts') + ';' + $env:Path
    & meson --version
    & 'C:\Program Files\Git\bin\bash.exe' (Join-Path $PSScriptRoot 'smoke_adapters.sh')
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $resolved = [System.IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
