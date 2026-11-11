#Requires -Version 5.1
<#
    Tests for build\Build-Release.ps1 and the release metadata (Pester 5 or later).
    Safe anywhere: they only write to Pester's temporary TestDrive.

    Run:  Invoke-Pester -Path .\tests\Build.Tests.ps1 -Output Detailed
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent
    . (Join-Path -Path $script:RepoRoot -ChildPath 'build\Build-Release.ps1')
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $script:Version = Get-ShareDoctorVersion -ScriptPath (Join-Path -Path $script:RepoRoot -ChildPath 'ShareDoctor.ps1')
}

Describe 'Version' {
    It 'reads a release version from ShareDoctor.ps1' {
        Test-ReleaseVersion -Version $script:Version | Should -BeTrue
    }

    It 'matches the version ShareDoctor.ps1 reports when loaded' {
        $loaded = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ". '$(Join-Path -Path $script:RepoRoot -ChildPath 'ShareDoctor.ps1')'; `$ShareDoctorVersion"
        $loaded | Should -BeExactly $script:Version
    }

    It 'accepts only X.Y.Z versions' {
        Test-ReleaseVersion -Version '1.2.3' | Should -BeTrue
        Test-ReleaseVersion -Version 'v1.2.3' | Should -BeFalse
        Test-ReleaseVersion -Version '1.2' | Should -BeFalse
        Test-ReleaseVersion -Version '1.2.3-beta' | Should -BeFalse
    }

    It 'refuses a version that is not a plain string' {
        $computed = Join-Path -Path $TestDrive -ChildPath 'computed.ps1'
        [System.IO.File]::WriteAllText($computed, "`$ShareDoctorVersion = '1.' + '0.0'`r`n")
        { Get-ShareDoctorVersion -ScriptPath $computed } | Should -Throw
    }

    It 'has a CHANGELOG.md section for the current version' {
        $section = Get-ChangelogSection -ChangelogPath (Join-Path -Path $script:RepoRoot -ChildPath 'CHANGELOG.md') -Version $script:Version
        $section | Should -Not -BeNullOrEmpty
    }

    It 'shows the version in the README status section' {
        [System.IO.File]::ReadAllText((Join-Path -Path $script:RepoRoot -ChildPath 'README.md')) | Should -Match ([regex]::Escape("v$($script:Version)"))
    }
}

Describe 'Get-ChangelogSection' {
    BeforeAll {
        $script:Changelog = Join-Path -Path $TestDrive -ChildPath 'CHANGELOG.md'
        $text = @(
            '# Changelog', '', '## [Unreleased]', '', '## [1.1.0] - 2026-01-02', '', '### Fixed', '', '- A fix.', '',
            '## [1.0.0] - 2026-01-01', '', '- First.', '', '[1.1.0]: https://example.com/1.1.0', '[1.0.0]: https://example.com/1.0.0'
        ) -join "`n"
        [System.IO.File]::WriteAllText($script:Changelog, $text)
    }

    It 'returns only the section for the version' {
        Get-ChangelogSection -ChangelogPath $script:Changelog -Version '1.1.0' | Should -BeExactly "### Fixed`n`n- A fix."
    }

    It 'leaves out link definitions at the end' {
        Get-ChangelogSection -ChangelogPath $script:Changelog -Version '1.0.0' | Should -BeExactly '- First.'
    }

    It 'fails for a version with no section' {
        { Get-ChangelogSection -ChangelogPath $script:Changelog -Version '9.9.9' } | Should -Throw '*no section*'
    }

    It 'fails for an empty section' {
        { Get-ChangelogSection -ChangelogPath $script:Changelog -Version 'Unreleased' } | Should -Throw '*empty*'
    }
}

Describe 'Release zip' {
    BeforeAll {
        $script:OutDir = Join-Path -Path $TestDrive -ChildPath 'dist'
        $script:Package = New-ReleasePackage -RepoRoot $script:RepoRoot -OutputDirectory $script:OutDir -ZipName (Get-ReleaseZipName -Version $script:Version)
    }

    It 'is named after the version' {
        Get-ReleaseZipName -Version '0.2.0' | Should -BeExactly 'ShareDoctor-v0.2.0.zip'
        Split-Path -Path $script:Package.ZipPath -Leaf | Should -BeExactly "ShareDoctor-v$($script:Version).zip"
    }

    It 'adds the build number to CI builds' {
        Get-ReleaseZipName -Version '0.2.0' -BuildNumber 42 | Should -BeExactly 'ShareDoctor-v0.2.0-build.42.zip'
    }

    It 'contains exactly ShareDoctor.ps1, ShareDoctor.cmd, README.md and LICENSE' {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($script:Package.ZipPath)
        try {
            @($zip.Entries | ForEach-Object { $_.FullName } | Sort-Object) | Should -Be @('LICENSE', 'README.md', 'ShareDoctor.cmd', 'ShareDoctor.ps1')
        } finally {
            $zip.Dispose()
        }
    }

    It 'keeps every file byte for byte, so CRLF line endings survive' {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($script:Package.ZipPath)
        try {
            foreach ($entry in $zip.Entries) {
                $reader = $entry.Open()
                $memory = [System.IO.MemoryStream]::new()
                try { $reader.CopyTo($memory) } finally { $reader.Dispose() }
                $original = [System.IO.File]::ReadAllBytes((Join-Path -Path $script:RepoRoot -ChildPath $entry.FullName))
                [System.Convert]::ToBase64String($memory.ToArray()) | Should -BeExactly ([System.Convert]::ToBase64String($original)) -Because $entry.FullName
                if ($entry.FullName -match '\.(ps1|cmd)$') {
                    [System.Text.Encoding]::ASCII.GetString($memory.ToArray()) -match '(?<!\r)\n' | Should -BeFalse -Because "$($entry.FullName) needs CRLF"
                }
            }
        } finally {
            $zip.Dispose()
        }
    }

    It 'writes a matching SHA-256 file' {
        $line = [System.IO.File]::ReadAllText($script:Package.ShaPath).Trim()
        $line | Should -BeExactly "$($script:Package.Sha256)  $(Split-Path -Path $script:Package.ZipPath -Leaf)"
        (Get-FileHash -LiteralPath $script:Package.ZipPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $script:Package.Sha256
    }

    It 'can be built again over an existing zip' {
        { New-ReleasePackage -RepoRoot $script:RepoRoot -OutputDirectory $script:OutDir -ZipName (Get-ReleaseZipName -Version $script:Version) } | Should -Not -Throw
    }
}

Describe 'Get-ReleaseFooter' {
    BeforeAll {
        $script:Footer = Get-ReleaseFooter -ZipName 'ShareDoctor-v0.2.0.zip' -Sha256 ('ab' * 32) -Repository 'owner/ShareDoctor' `
            -Commit '31e12090a3796843c37eaa827ee80248dd345005' -RunNumber '4'
        $script:FooterLines = $script:Footer -split "`n"
    }

    It 'keeps every sentence on one line' {
        $script:FooterLines | Should -Contain '**Download:** `ShareDoctor-v0.2.0.zip` below. Unzip it on both PCs, then follow the [Quick start](https://github.com/owner/ShareDoctor#quick-start).'
        $script:FooterLines | Should -Contain 'Release build 4 from commit [31e1209](https://github.com/owner/ShareDoctor/commit/31e12090a3796843c37eaa827ee80248dd345005).'
        $script:FooterLines | Should -Contain ('SHA-256: `' + ('ab' * 32) + '`')
    }

    It 'starts with a separator and has no stray lines' {
        $script:FooterLines.Count | Should -Be 8
        $script:FooterLines[1] | Should -BeExactly '---'
        @($script:FooterLines | Where-Object { $_ -eq '`' }).Count | Should -Be 0
    }

    It 'refuses something that is not a commit hash' {
        { Get-ReleaseFooter -ZipName 'a.zip' -Sha256 'x' -Repository 'o/r' -Commit 'main; rm' -RunNumber '1' } | Should -Throw
    }
}

Describe 'Invoke-Build' {
    It 'builds with the tag as the expected version and writes the release notes' {
        $outDir = Join-Path -Path $TestDrive -ChildPath 'tagged'
        $notes = Join-Path -Path $TestDrive -ChildPath 'notes\release-notes.md'
        $package = Invoke-Build -OutputDirectory $outDir -ExpectedVersion "v$($script:Version)" -NotesPath $notes
        Test-Path -LiteralPath $package.ZipPath | Should -BeTrue
        [System.IO.File]::ReadAllText($notes) | Should -Not -BeNullOrEmpty
    }

    It 'fails when the tag does not match the script version' {
        { Invoke-Build -OutputDirectory (Join-Path -Path $TestDrive -ChildPath 'bad') -ExpectedVersion 'v99.0.0' } | Should -Throw '*Version mismatch*'
    }

    It 'names CI builds with the build number' {
        $package = Invoke-Build -OutputDirectory (Join-Path -Path $TestDrive -ChildPath 'ci') -BuildNumber 7
        Split-Path -Path $package.ZipPath -Leaf | Should -BeExactly "ShareDoctor-v$($script:Version)-build.7.zip"
    }
}
