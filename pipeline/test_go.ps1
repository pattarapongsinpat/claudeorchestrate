$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('claudeorchestrate-go-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $releases = Invoke-RestMethod -Uri 'https://go.dev/dl/?mode=json'
    $file = $releases.files | Where-Object {
        $_.os -eq 'windows' -and $_.arch -eq 'amd64' -and $_.kind -eq 'archive'
    } | Select-Object -First 1
    if (-not $file) { throw 'No stable Windows amd64 Go archive was found.' }
    $archive = Join-Path $testRoot $file.filename
    Invoke-WebRequest -Uri "https://go.dev/dl/$($file.filename)" -OutFile $archive
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash -ne $file.sha256) {
        throw 'Go SHA256 checksum mismatch.'
    }
    $root = Join-Path $testRoot 'toolchain'
    Expand-Archive -LiteralPath $archive -DestinationPath $root
    $go = Get-ChildItem -LiteralPath $root -Recurse -Filter go.exe | Where-Object { $_.Directory.Name -eq 'bin' } | Select-Object -First 1
    if (-not $go) { throw 'Go executable was not found.' }
    $env:Path = $go.Directory.FullName + ';' + $env:Path
    & $go.FullName version
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
