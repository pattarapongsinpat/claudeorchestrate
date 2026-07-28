param(
    [string]$JdkVersion = '21.0.12',
    [string]$MavenVersion = '3.9.16'
)

$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('claudeochestrate-java-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

function Assert-Checksum([string]$Archive, [string]$ChecksumFile, [string]$Algorithm) {
    $expected = ((Get-Content -Raw -LiteralPath $ChecksumFile).Trim() -split '\s+')[0]
    $actual = (Get-FileHash -Algorithm $Algorithm -LiteralPath $Archive).Hash
    if ($actual -ne $expected) {
        throw "$Algorithm checksum mismatch for $Archive"
    }
}

try {
    $jdkName = "microsoft-jdk-$JdkVersion-windows-x64.zip"
    $jdkArchive = Join-Path $testRoot $jdkName
    $jdkChecksum = "$jdkArchive.sha256sum.txt"
    $jdkBase = "https://aka.ms/download-jdk/$jdkName"
    Invoke-WebRequest -Uri $jdkBase -OutFile $jdkArchive
    Invoke-WebRequest -Uri "$jdkBase.sha256sum.txt" -OutFile $jdkChecksum
    Assert-Checksum $jdkArchive $jdkChecksum SHA256

    $mavenName = "apache-maven-$MavenVersion-bin.zip"
    $mavenArchive = Join-Path $testRoot $mavenName
    $mavenChecksum = "$mavenArchive.sha512"
    $mavenBase = "https://dlcdn.apache.org/maven/maven-3/$MavenVersion/binaries/$mavenName"
    Invoke-WebRequest -Uri $mavenBase -OutFile $mavenArchive
    Invoke-WebRequest -Uri "$mavenBase.sha512" -OutFile $mavenChecksum
    Assert-Checksum $mavenArchive $mavenChecksum SHA512

    $jdkRoot = Join-Path $testRoot 'jdk'
    $mavenRoot = Join-Path $testRoot 'maven'
    Expand-Archive -LiteralPath $jdkArchive -DestinationPath $jdkRoot
    Expand-Archive -LiteralPath $mavenArchive -DestinationPath $mavenRoot

    $java = Get-ChildItem -LiteralPath $jdkRoot -Recurse -Filter java.exe |
        Where-Object { $_.Directory.Name -eq 'bin' } | Select-Object -First 1
    $maven = Get-ChildItem -LiteralPath $mavenRoot -Recurse -Filter mvn.cmd |
        Where-Object { $_.Directory.Name -eq 'bin' } | Select-Object -First 1
    if (-not $java -or -not $maven) {
        throw 'Portable Java toolchain extraction failed.'
    }

    $env:JAVA_HOME = $java.Directory.Parent.FullName
    $env:Path = $java.Directory.FullName + ';' + $maven.Directory.FullName + ';' + $env:Path
    & $java.FullName --version
    & $maven.FullName --version

    $invoke = Join-Path $PSScriptRoot 'invoke.ps1'
    & (Join-Path $PSHOME 'powershell.exe') -ExecutionPolicy Bypass -File $invoke smoke_adapters
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}
finally {
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $resolved = [System.IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
