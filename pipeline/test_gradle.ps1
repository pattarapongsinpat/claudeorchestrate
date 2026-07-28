param([string]$JdkVersion = '21.0.12')
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('claudeorchestrate-gradle-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$errorLog = Join-Path (Split-Path $PSScriptRoot -Parent) '.pipeline\test_gradle_error.log'
New-Item -ItemType Directory -Path (Split-Path $errorLog -Parent) -Force | Out-Null
Remove-Item -LiteralPath $errorLog -Force -ErrorAction SilentlyContinue

function Assert-Hash([string]$Archive, [string]$Expected) {
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $Archive).Hash -ne $Expected.Trim()) {
        throw "SHA256 checksum mismatch for $Archive"
    }
}

try {
    $jdkName = "microsoft-jdk-$JdkVersion-windows-x64.zip"
    $jdkUrl = "https://aka.ms/download-jdk/$jdkName"
    $jdkArchive = Join-Path $testRoot $jdkName
    $jdkChecksum = "$jdkArchive.sha256sum.txt"
    Invoke-WebRequest -Uri $jdkUrl -OutFile $jdkArchive
    Invoke-WebRequest -Uri "$jdkUrl.sha256sum.txt" -OutFile $jdkChecksum
    Assert-Hash $jdkArchive (((Get-Content -Raw -LiteralPath $jdkChecksum).Trim() -split '\s+')[0])
    $jdkRoot = Join-Path $testRoot 'jdk'
    Expand-Archive -LiteralPath $jdkArchive -DestinationPath $jdkRoot

    $release = Invoke-RestMethod -Uri 'https://services.gradle.org/versions/current'
    $gradleArchive = Join-Path $testRoot "gradle-$($release.version)-bin.zip"
    $gradleChecksum = "$gradleArchive.sha256"
    Invoke-WebRequest -Uri $release.downloadUrl -OutFile $gradleArchive
    Invoke-WebRequest -Uri $release.checksumUrl -OutFile $gradleChecksum
    Assert-Hash $gradleArchive (Get-Content -Raw -LiteralPath $gradleChecksum)
    $gradleRoot = Join-Path $testRoot 'gradle'
    Expand-Archive -LiteralPath $gradleArchive -DestinationPath $gradleRoot

    $java = Get-ChildItem -LiteralPath $jdkRoot -Recurse -Filter java.exe | Where-Object { $_.Directory.Name -eq 'bin' } | Select-Object -First 1
    $gradle = Get-ChildItem -LiteralPath $gradleRoot -Recurse -Filter gradle.bat | Where-Object { $_.Directory.Name -eq 'bin' } | Select-Object -First 1
    if (-not $java -or -not $gradle) { throw 'Gradle test toolchain extraction failed.' }
    $env:JAVA_HOME = $java.Directory.Parent.FullName
    $env:Path = $java.Directory.FullName + ';' + $gradle.Directory.FullName + ';' + $env:Path
    & $java.FullName --version
    & $gradle.FullName --version
    $env:SMOKE_ONLY = 'gradle'
    & 'C:\Program Files\Git\bin\bash.exe' (Join-Path $PSScriptRoot 'smoke_adapters.sh') 2>&1 |
        Tee-Object -FilePath (Join-Path (Split-Path $PSScriptRoot -Parent) '.pipeline\test_gradle_smoke.log')
    if ($LASTEXITCODE -ne 0) { throw 'Gradle smoke adapter failed.' }
}
catch {
    ($_ | Out-String) | Set-Content -LiteralPath $errorLog
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
