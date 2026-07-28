param(
    [string]$JdkVersion = '21.0.12',
    [string]$MavenVersion = '3.9.16',
    [string]$MesonVersion = '1.9.1'
)

$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('claudeorchestrate-all-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

function Assert-Hash([string]$Archive, [string]$Expected, [string]$Algorithm) {
    $actual = (Get-FileHash -Algorithm $Algorithm -LiteralPath $Archive).Hash
    if ($actual -ne $Expected.Trim()) {
        throw "$Algorithm checksum mismatch for $Archive"
    }
}

function Download-ChecksumFile([string]$ArchiveUrl, [string]$ChecksumUrl, [string]$Archive, [string]$Algorithm) {
    $checksum = "$Archive.checksum"
    Invoke-WebRequest -Uri $ArchiveUrl -OutFile $Archive
    Invoke-WebRequest -Uri $ChecksumUrl -OutFile $checksum
    $expected = ((Get-Content -Raw -LiteralPath $checksum).Trim() -split '\s+')[0]
    Assert-Hash $Archive $expected $Algorithm
}

try {
    Write-Output 'Preparing Microsoft OpenJDK.'
    $jdkName = "microsoft-jdk-$JdkVersion-windows-x64.zip"
    $jdkArchive = Join-Path $testRoot $jdkName
    $jdkUrl = "https://aka.ms/download-jdk/$jdkName"
    Download-ChecksumFile $jdkUrl "$jdkUrl.sha256sum.txt" $jdkArchive SHA256
    $jdkRoot = Join-Path $testRoot 'jdk'
    Expand-Archive -LiteralPath $jdkArchive -DestinationPath $jdkRoot

    Write-Output 'Preparing Apache Maven.'
    $mavenName = "apache-maven-$MavenVersion-bin.zip"
    $mavenArchive = Join-Path $testRoot $mavenName
    $mavenUrl = "https://dlcdn.apache.org/maven/maven-3/$MavenVersion/binaries/$mavenName"
    Download-ChecksumFile $mavenUrl "$mavenUrl.sha512" $mavenArchive SHA512
    $mavenRoot = Join-Path $testRoot 'maven'
    Expand-Archive -LiteralPath $mavenArchive -DestinationPath $mavenRoot

    Write-Output 'Preparing Gradle.'
    $gradleRelease = Invoke-RestMethod -Uri 'https://services.gradle.org/versions/current'
    $gradleArchive = Join-Path $testRoot "gradle-$($gradleRelease.version)-bin.zip"
    Download-ChecksumFile $gradleRelease.downloadUrl $gradleRelease.checksumUrl $gradleArchive SHA256
    $gradleRoot = Join-Path $testRoot 'gradle'
    Expand-Archive -LiteralPath $gradleArchive -DestinationPath $gradleRoot

    Write-Output 'Preparing Go.'
    $goReleases = Invoke-RestMethod -Uri 'https://go.dev/dl/?mode=json'
    $goFile = $goReleases.files | Where-Object {
        $_.os -eq 'windows' -and $_.arch -eq 'amd64' -and $_.kind -eq 'archive'
    } | Select-Object -First 1
    if (-not $goFile) { throw 'No stable Windows amd64 Go archive was found.' }
    $goArchive = Join-Path $testRoot $goFile.filename
    Invoke-WebRequest -Uri "https://go.dev/dl/$($goFile.filename)" -OutFile $goArchive
    Assert-Hash $goArchive $goFile.sha256 SHA256
    $goRoot = Join-Path $testRoot 'golang'
    Expand-Archive -LiteralPath $goArchive -DestinationPath $goRoot

    Write-Output 'Preparing Meson.'
    $venv = Join-Path $testRoot 'python'
    & python -m venv $venv
    $venvPython = Join-Path $venv 'Scripts\python.exe'
    & $venvPython -m pip install --disable-pip-version-check --quiet "meson==$MesonVersion" pytest
    if ($LASTEXITCODE -ne 0) { throw 'Meson and pytest installation failed.' }

    Write-Output 'Preparing GNU Make.'
    $makeDownload = Join-Path $testRoot 'make-download'
    New-Item -ItemType Directory -Path $makeDownload | Out-Null
    & winget download --id GnuWin32.Make --exact --download-directory $makeDownload --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) { throw 'Winget could not download GNU Make.' }
    $makeInstaller = Get-ChildItem -LiteralPath $makeDownload -Filter '*.exe' | Select-Object -First 1
    if (-not $makeInstaller) { throw 'Winget did not produce a GNU Make installer.' }
    Assert-Hash $makeInstaller.FullName 'cc55115c78a16386587c6eb90dd35e6de820191b83a6b3058460e5661f457e3f' SHA256
    $innoDownload = Join-Path $testRoot 'innoextract-download'
    New-Item -ItemType Directory -Path $innoDownload | Out-Null
    & winget download --id dscharrer.innoextract --exact --download-directory $innoDownload --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) { throw 'Winget could not download innoextract.' }
    $innoArchive = Get-ChildItem -LiteralPath $innoDownload -Filter '*.zip' | Select-Object -First 1
    if (-not $innoArchive) { throw 'Winget did not produce an innoextract archive.' }
    Assert-Hash $innoArchive.FullName '6989342c9b026a00a72a38f23b62a8e6a22cc5de69805cf47d68ac2fec993065' SHA256
    $innoRoot = Join-Path $testRoot 'innoextract'
    Expand-Archive -LiteralPath $innoArchive.FullName -DestinationPath $innoRoot
    $innoextract = Get-ChildItem -LiteralPath $innoRoot -Recurse -Filter innoextract.exe | Select-Object -First 1
    if (-not $innoextract) { throw 'innoextract failed to extract.' }

    $makeRoot = Join-Path $testRoot 'make'
    & $innoextract.FullName --silent --extract --output-dir $makeRoot $makeInstaller.FullName
    if ($LASTEXITCODE -ne 0) { throw 'GNU Make archive extraction failed.' }

    $java = Get-ChildItem -LiteralPath $jdkRoot -Recurse -Filter java.exe | Where-Object { $_.Directory.Name -eq 'bin' } | Select-Object -First 1
    $maven = Get-ChildItem -LiteralPath $mavenRoot -Recurse -Filter mvn.cmd | Where-Object { $_.Directory.Name -eq 'bin' } | Select-Object -First 1
    $gradle = Get-ChildItem -LiteralPath $gradleRoot -Recurse -Filter gradle.bat | Where-Object { $_.Directory.Name -eq 'bin' } | Select-Object -First 1
    $go = Get-ChildItem -LiteralPath $goRoot -Recurse -Filter go.exe | Where-Object { $_.Directory.Name -eq 'bin' } | Select-Object -First 1
    $meson = Join-Path $venv 'Scripts'
    $make = Get-ChildItem -LiteralPath $makeRoot -Recurse -Filter make.exe | Select-Object -First 1
    if (-not $java -or -not $maven -or -not $gradle -or -not $go -or -not $make) {
        throw 'One or more portable toolchains failed to extract.'
    }

    $env:JAVA_HOME = $java.Directory.Parent.FullName
    $toolPaths = @($java.Directory.FullName, $maven.Directory.FullName, $gradle.Directory.FullName, $go.Directory.FullName, $meson, $make.Directory.FullName)
    $env:Path = ($toolPaths -join ';') + ';' + $env:Path

    Write-Output 'Portable toolchains ready. Reporting versions.'
    & $java.FullName --version
    & $maven.FullName --version
    & $gradle.FullName --version
    & $go.FullName version
    & (Join-Path $meson 'meson.exe') --version
    & $make.FullName --version

    Write-Output 'Starting complete adapter smoke suite.'
    $invoke = Join-Path $PSScriptRoot 'invoke.ps1'
    & (Join-Path $PSHOME 'powershell.exe') -ExecutionPolicy Bypass -File $invoke smoke_adapters
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
catch {
    Write-Error $_
    throw
}
finally {
    if ($gradle) {
        & $gradle.FullName --stop 2>$null | Out-Null
    }
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $resolved = [System.IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        for ($attempt = 1; $attempt -le 3 -and (Test-Path -LiteralPath $resolved); $attempt++) {
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $resolved) { Start-Sleep -Seconds 1 }
        }
    }
}
