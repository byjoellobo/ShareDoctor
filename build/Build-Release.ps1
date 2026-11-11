#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the ShareDoctor release zip (SPEC.md section 14).

.DESCRIPTION
    Creates dist\ShareDoctor-vX.Y.Z.zip containing ShareDoctor.ps1, ShareDoctor.cmd, README.md and
    LICENSE. Files are copied byte for byte, so the CRLF line endings that Windows PowerShell 5.1
    and cmd.exe need are kept. A matching .sha256 file is written next to the zip.

    The version comes from $ShareDoctorVersion in ShareDoctor.ps1.

    Dot-sourcing this file only loads its functions (the tests rely on this).

.PARAMETER OutputDirectory
    Where to write the zip. Default: dist\ in the repository.
.PARAMETER ExpectedVersion
    Fail unless ShareDoctor.ps1 has this version. A leading "v" is ignored, so a tag such as
    v0.2.0 can be passed as it is. Also requires a CHANGELOG.md section for the version.
.PARAMETER BuildNumber
    For CI builds: names the zip ShareDoctor-vX.Y.Z-build.N.zip.
.PARAMETER NotesPath
    Also write this version's CHANGELOG.md section to this file, for the GitHub Release notes.

.EXAMPLE
    .\build\Build-Release.ps1

.EXAMPLE
    .\build\Build-Release.ps1 -ExpectedVersion v0.2.0 -NotesPath dist\release-notes.md
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory = '',
    [string]$ExpectedVersion = '',
    [ValidateRange(0, 2147483647)]
    [int]$BuildNumber = 0,
    [string]$NotesPath = ''
)

$ReleaseFiles = @('ShareDoctor.ps1', 'ShareDoctor.cmd', 'README.md', 'LICENSE')

function Get-ShareDoctorVersion {
    # Reads $ShareDoctorVersion from the script without running it.
    param([Parameter(Mandatory)] [string]$ScriptPath)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
    $assignment = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$ShareDoctorVersion'
        }, $false)
    if (-not $assignment) { throw "No `$ShareDoctorVersion found in $ScriptPath." }
    $value = $assignment.Right.Expression
    if ($value -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
        throw "`$ShareDoctorVersion in $ScriptPath must be a plain string such as '1.2.3'."
    }
    return $value.Value
}

function Test-ReleaseVersion([string]$Version) {
    return ($Version -match '^\d+\.\d+\.\d+$')
}

function Get-ReleaseZipName([string]$Version, [int]$BuildNumber = 0) {
    if ($BuildNumber -gt 0) { return "ShareDoctor-v$Version-build.$BuildNumber.zip" }
    return "ShareDoctor-v$Version.zip"
}

function Get-ChangelogSection {
    # Returns the text under "## [X.Y.Z]" up to the next "## [" heading, without link definitions.
    param([Parameter(Mandatory)] [string]$ChangelogPath, [Parameter(Mandatory)] [string]$Version)
    $lines = [System.IO.File]::ReadAllLines($ChangelogPath)
    $heading = '^## \[' + [regex]::Escape($Version) + '\]'
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $heading) { $start = $i; break }
    }
    if ($start -lt 0) { throw "CHANGELOG.md has no section for version $Version. Add one before releasing." }
    $body = @()
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^## \[') { break }
        if ($lines[$i] -match '^\[[^\]]+\]:\s') { continue }
        $body += $lines[$i]
    }
    $text = ($body -join "`n").Trim()
    if (-not $text) { throw "The CHANGELOG.md section for version $Version is empty." }
    return $text
}

function New-ReleasePackage {
    # Writes the zip and its .sha256 file. Returns { ZipPath, Sha256, ShaPath }.
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [Parameter(Mandatory)] [string]$OutputDirectory,
        [Parameter(Mandatory)] [string]$ZipName
    )
    Add-Type -AssemblyName System.IO.Compression
    foreach ($name in $ReleaseFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path -Path $RepoRoot -ChildPath $name) -PathType Leaf)) { throw "Release file missing: $name" }
    }
    [void][System.IO.Directory]::CreateDirectory($OutputDirectory)
    $zipPath = Join-Path -Path $OutputDirectory -ChildPath $ZipName
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

    $stream = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::CreateNew)
    try {
        $archive = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($name in $ReleaseFiles) {
                $source = Join-Path -Path $RepoRoot -ChildPath $name
                $entry = $archive.CreateEntry($name, [System.IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = [System.IO.File]::GetLastWriteTime($source)
                $bytes = [System.IO.File]::ReadAllBytes($source)
                $writer = $entry.Open()
                try { $writer.Write($bytes, 0, $bytes.Length) } finally { $writer.Dispose() }
            }
        } finally {
            $archive.Dispose()
        }
    } finally {
        $stream.Dispose()
    }

    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $shaPath = "$zipPath.sha256"
    [System.IO.File]::WriteAllText($shaPath, "$hash  $ZipName`n", [System.Text.Encoding]::ASCII)
    return [pscustomobject]@{ ZipPath = $zipPath; Sha256 = $hash; ShaPath = $shaPath }
}

function Resolve-FullPath([string]$Path) {
    # Relative to the current PowerShell location (not the process directory). The path may not exist yet.
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Invoke-Build {
    param(
        [string]$OutputDirectory = '',
        [string]$ExpectedVersion = '',
        [int]$BuildNumber = 0,
        [string]$NotesPath = ''
    )
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $outDir = if ($OutputDirectory) { Resolve-FullPath -Path $OutputDirectory } else { Join-Path -Path $repoRoot -ChildPath 'dist' }
    $version = Get-ShareDoctorVersion -ScriptPath (Join-Path -Path $repoRoot -ChildPath 'ShareDoctor.ps1')
    if (-not (Test-ReleaseVersion -Version $version)) { throw "'$version' is not a release version (expected X.Y.Z)." }

    $changelog = Join-Path -Path $repoRoot -ChildPath 'CHANGELOG.md'
    $notes = ''
    if ($ExpectedVersion -or $NotesPath) {
        $expected = $ExpectedVersion -replace '^v', ''
        if ($ExpectedVersion -and $expected -ne $version) {
            throw "Version mismatch: the tag says $expected but ShareDoctor.ps1 says $version. Bump `$ShareDoctorVersion or fix the tag."
        }
        $notes = Get-ChangelogSection -ChangelogPath $changelog -Version $version
    }

    $package = New-ReleasePackage -RepoRoot $repoRoot -OutputDirectory $outDir -ZipName (Get-ReleaseZipName -Version $version -BuildNumber $BuildNumber)
    if ($NotesPath) {
        $notesFile = Resolve-FullPath -Path $NotesPath
        [void][System.IO.Directory]::CreateDirectory((Split-Path -Path $notesFile -Parent))
        [System.IO.File]::WriteAllText($notesFile, "$notes`n", [System.Text.UTF8Encoding]::new($false))
    }
    Write-Information -MessageData "Built $($package.ZipPath) (ShareDoctor $version, SHA-256 $($package.Sha256))" -InformationAction Continue
    return $package
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Build -OutputDirectory $OutputDirectory -ExpectedVersion $ExpectedVersion -BuildNumber $BuildNumber -NotesPath $NotesPath
}
