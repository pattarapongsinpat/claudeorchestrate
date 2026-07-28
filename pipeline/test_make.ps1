$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('claudeochestrate-make-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

function Download-Winget([string]$Id, [string]$Directory, [string]$Hash, [string]$Extension) {
    New-Item -ItemType Directory -Path $Directory | Out-Null
    & winget download --id $Id --exact --download-directory $Directory --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) { throw "Winget could not download $Id." }
    $artifact = Get-ChildItem -LiteralPath $Directory -Filter "*$Extension" | Select-Object -First 1
    if (-not $artifact) { throw "Winget did not produce $Extension for $Id." }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $artifact.FullName).Hash -ne $Hash) {
        throw "SHA256 checksum mismatch for $Id."
    }
    return $artifact
}

try {
    Write-Output 'Downloading verified GNU Make and innoextract packages.'
    $makeInstaller = Download-Winget 'GnuWin32.Make' (Join-Path $testRoot 'make-download') 'cc55115c78a16386587c6eb90dd35e6de820191b83a6b3058460e5661f457e3f' '.exe'
    $innoArchive = Download-Winget 'dscharrer.innoextract' (Join-Path $testRoot 'inno-download') '6989342c9b026a00a72a38f23b62a8e6a22cc5de69805cf47d68ac2fec993065' '.zip'

    $innoRoot = Join-Path $testRoot 'inno'
    Expand-Archive -LiteralPath $innoArchive.FullName -DestinationPath $innoRoot
    $innoextract = Get-ChildItem -LiteralPath $innoRoot -Recurse -Filter innoextract.exe | Select-Object -First 1
    if (-not $innoextract) { throw 'innoextract executable was not found.' }

    $makeRoot = Join-Path $testRoot 'make'
    & $innoextract.FullName --silent --extract --output-dir $makeRoot $makeInstaller.FullName
    if ($LASTEXITCODE -ne 0) { throw 'GNU Make archive extraction failed.' }
    $make = Get-ChildItem -LiteralPath $makeRoot -Recurse -Filter make.exe | Select-Object -First 1
    if (-not $make) { throw 'GNU Make executable was not found after extraction.' }

    $env:Path = $make.Directory.FullName + ';' + $env:Path
    & $make.FullName --version
    $invoke = Join-Path $PSScriptRoot 'invoke.ps1'
    & (Join-Path $PSHOME 'powershell.exe') -ExecutionPolicy Bypass -File $invoke smoke_adapters
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
catch {
    Write-Error $_
    exit 1
}
finally {
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $resolved = [System.IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
