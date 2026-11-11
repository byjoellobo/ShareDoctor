#Requires -Version 5.1
<#
    ShareDoctor integration test (Pester 5 or later, -Tag Integration). See SPEC.md section 13.4.

    WARNING: this test MAKES REAL CHANGES to the PC it runs on. It creates the local account
    'sdtest', the share 'SDTest' and a saved sign-in for 127.0.0.1, and Host may set networks to
    Private, enable firewall rules and start services. AfterAll always removes the account, the
    share, the saved sign-in, the sign-in screen entry and the temp folder, and puts the network
    types, firewall rules and services back the way they were, even after a failure.

    It runs in CI on windows-latest, which is elevated. Anywhere else it is skipped unless you
    opt in. On your own PC, run it only with the maintainer's explicit OK, from an elevated
    PowerShell:
        $env:SHAREDOCTOR_RUN_INTEGRATION = '1'
        Invoke-Pester -Path .\tests\Integration.Tests.ps1 -Tag Integration -Output Detailed
#>

BeforeDiscovery {
    $script:OptedIn = ($env:CI -eq 'true') -or ($env:SHAREDOCTOR_RUN_INTEGRATION -eq '1')
}

Describe 'ShareDoctor end to end over SMB loopback' -Tag 'Integration' -Skip:(-not $script:OptedIn) {
    BeforeAll {
        $script:ScriptPath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'ShareDoctor.ps1'
        . $script:ScriptPath   # functions only, for Test-ShareAccess and the constants

        if (-not (Test-IsAdmin)) { throw 'The integration test needs an elevated PowerShell (Run as administrator).' }

        $script:Share = 'SDTest'
        $script:User = 'sdtest'
        # Connect by IP, so the saved sign-in can never replace one saved for this PC's own name.
        $script:Target = '127.0.0.1'
        $script:Qualified = "$env:COMPUTERNAME\$($script:User)"
        $script:Unc = "\\$($script:Target)\$($script:Share)"

        $existing = Get-LocalUser -Name $script:User -ErrorAction SilentlyContinue
        if ($existing -and $existing.Description -ne $AccountTag) {
            throw "An account named '$($script:User)' already exists and ShareDoctor did not create it. Refusing to run."
        }
        if (Get-SmbShare -Name $script:Share -ErrorAction SilentlyContinue) {
            throw "A share named '$($script:Share)' already exists. Remove it before running this test."
        }
        if ((Invoke-Native -FilePath 'cmdkey.exe' -Arguments @("/list:$($script:Target)")).Output -match "target=$([regex]::Escape($script:Target))") {
            throw "A sign-in for $($script:Target) is already saved in Credential Manager. Refusing to overwrite it."
        }

        # What Host may change, so AfterAll can put it back.
        $script:NetworkSnapshot = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue |
                ForEach-Object { [pscustomobject]@{ Index = $_.InterfaceIndex; Category = "$($_.NetworkCategory)" } })
        $script:RuleSnapshot = @(foreach ($group in $FwGroupFileSharing, $FwGroupDiscovery) {
                Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Enabled = "$($_.Enabled)" } }
            })
        $script:ServiceSnapshot = @(foreach ($name in 'LanmanServer', 'FDResPub', 'fdPHost') {
                Get-Service -Name $name -ErrorAction SilentlyContinue |
                    ForEach-Object { [pscustomobject]@{ Name = $_.Name; StartType = "$($_.StartType)"; Running = ("$($_.Status)" -eq 'Running') } }
            })
        $script:Ready = $true   # from here on, AfterAll cleans up

        $script:Folder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('SDTest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [void][System.IO.Directory]::CreateDirectory($script:Folder)
        [System.IO.File]::WriteAllText((Join-Path -Path $script:Folder -ChildPath 'hello.txt'), 'hello from ShareDoctor')

        # A random password that meets the Windows complexity rules. Never printed.
        $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '#%+-=?_!')
        $bytes = [byte[]]::new(24)
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        $chars = for ($i = 0; $i -lt $bytes.Length; $i++) { $set = $sets[$i % $sets.Count]; $set[$bytes[$i] % $set.Length] }
        $script:Password = ConvertTo-SecureString -String (-join $chars) -AsPlainText -Force

        $script:Everyone = Get-EveryoneAccountName
        $script:HostArguments = @{
            Mode = 'Host'; Yes = $true; Path = $script:Folder; ShareName = $script:Share
            UserName = $script:User; Password = $script:Password
        }
    }

    AfterAll {
        # Always clean up, even when a test failed. Every step runs on its own, so one failure
        # never skips the rest. Only ever delete the account ShareDoctor made.
        if (-not $script:Ready) { return }
        $steps = @(
            { Get-SmbMapping -RemotePath $script:Unc -ErrorAction SilentlyContinue | Remove-SmbMapping -Force -ErrorAction Stop },
            { [void](Invoke-Native -FilePath 'net.exe' -Arguments @('use', $script:Unc, '/delete', '/y')) },
            { if (Get-SmbShare -Name $script:Share -ErrorAction SilentlyContinue) { Remove-SmbShare -Name $script:Share -Force -ErrorAction Stop } },
            {
                $leftover = Get-LocalUser -Name $script:User -ErrorAction SilentlyContinue
                if ($leftover -and $leftover.Description -eq $AccountTag) { Remove-LocalUser -Name $script:User -ErrorAction Stop }
            },
            { [void](Invoke-Native -FilePath 'cmdkey.exe' -Arguments @("/delete:$($script:Target)")) },
            { Remove-ItemProperty -Path $SignInListKey -Name $script:User -ErrorAction SilentlyContinue },
            { if ($script:Folder -and (Test-Path -LiteralPath $script:Folder)) { Remove-Item -LiteralPath $script:Folder -Recurse -Force -ErrorAction Stop } },
            {
                # Host only ever turns Public networks into Private ones.
                foreach ($network in @($script:NetworkSnapshot | Where-Object { $_.Category -eq 'Public' })) {
                    Set-NetConnectionProfile -InterfaceIndex $network.Index -NetworkCategory Public -ErrorAction Stop
                }
            },
            {
                $wereOff = @($script:RuleSnapshot | Where-Object { $_.Enabled -ne 'True' } | ForEach-Object { $_.Name })
                if ($wereOff.Count -gt 0) { Disable-NetFirewallRule -Name $wereOff -ErrorAction Stop }
            },
            {
                foreach ($service in $script:ServiceSnapshot) {
                    $now = Get-Service -Name $service.Name
                    if ("$($now.StartType)" -ne $service.StartType) { Set-Service -Name $service.Name -StartupType $service.StartType -ErrorAction Stop }
                    if (-not $service.Running -and "$($now.Status)" -eq 'Running') { Stop-Service -Name $service.Name -Force -ErrorAction Stop }
                }
            }
        )
        foreach ($step in $steps) {
            try { & $step } catch { Write-Warning "A cleanup step failed: $($_.Exception.Message)" }
        }
    }

    It 'Host shares the folder with a hidden, marked share account' {
        $hostArguments = $script:HostArguments
        & $script:ScriptPath @hostArguments
        $LASTEXITCODE | Should -Be 0

        $share = Get-SmbShare -Name $script:Share -ErrorAction SilentlyContinue
        $share | Should -Not -BeNullOrEmpty
        $share.Path.TrimEnd('\') | Should -Be $script:Folder.TrimEnd('\')

        (Get-LocalUser -Name $script:User).Description | Should -BeExactly $AccountTag
        (Get-ItemProperty -Path $SignInListKey -Name $script:User).($script:User) | Should -Be 0

        $folderAccounts = @((Get-Acl -LiteralPath $script:Folder).Access | ForEach-Object { "$($_.IdentityReference)" })
        $folderAccounts | Should -Contain $script:Qualified

        $shareAccounts = @(Get-SmbShareAccess -Name $script:Share | ForEach-Object { $_.AccountName })
        $shareAccounts | Should -Contain $script:Qualified
        $shareAccounts | Should -Not -Contain $script:Everyone
    }

    It 'Host is idempotent: a second run succeeds and still leaves one share' {
        $hostArguments = $script:HostArguments
        & $script:ScriptPath @hostArguments
        $LASTEXITCODE | Should -Be 0
        @(Get-SmbShare | Where-Object { $_.Name -eq $script:Share }).Count | Should -Be 1
        @(Get-LocalUser | Where-Object { $_.Name -eq $script:User }).Count | Should -Be 1
    }

    It 'Connect reaches this PC, saves the sign-in and tests access' {
        $connectArguments = @{
            Mode = 'Connect'; Yes = $true; Computer = $script:Target; ShareName = $script:Share
            UserName = $script:Qualified; Password = $script:Password; NoDriveLetter = $true; NoOpen = $true
        }
        $lines = @(& $script:ScriptPath @connectArguments 6>&1 | ForEach-Object { "$_" })
        $exitCode = $LASTEXITCODE
        $lines | ForEach-Object { Write-Host $_ }
        $text = $lines -join "`n"
        $text | Should -Match 'is accepting file sharing connections'
        $text | Should -Match 'Sign-in saved in Windows Credential Manager'
        # Over SMB loopback Windows signs in to its own shares with the caller's own token and
        # ignores saved sign-ins, so Connect's access test can only report "Access denied" (5)
        # here. Between two PCs the saved sign-in is used: manual test M2 in docs/TESTING.md.
        if ($exitCode -ne 0) {
            $exitCode | Should -Be 1
            $text | Should -Match 'Access denied' -Because 'the only expected loopback failure is error 5'
        }
    }

    It 'The share account can read and change files over SMB' {
        # SPEC.md 13.4 fallback: sign in explicitly as the share account, because loopback ignores saved sign-ins.
        $plain = [System.Net.NetworkCredential]::new('', $script:Password).Password
        try {
            New-SmbMapping -RemotePath $script:Unc -UserName $script:Qualified -Password $plain -Persistent $false -ErrorAction Stop | Out-Null
        } finally {
            $plain = $null
        }
        $access = Test-ShareAccess -Unc $script:Unc
        $access.Code | Should -Be 0 -Because $access.Message
        [System.IO.File]::ReadAllText((Join-Path -Path $script:Unc -ChildPath 'hello.txt')) | Should -BeExactly 'hello from ShareDoctor'
        [System.IO.File]::WriteAllText((Join-Path -Path $script:Unc -ChildPath 'written-over-smb.txt'), 'change access works')
        Test-Path -LiteralPath (Join-Path -Path $script:Folder -ChildPath 'written-over-smb.txt') | Should -BeTrue
    }

    It 'Diagnose reports no failure for the share access check' {
        $output = & $script:ScriptPath -Mode Diagnose -Yes -Json -Computer $script:Target -ShareName $script:Share
        $LASTEXITCODE | Should -BeIn @(0, 3)
        $report = ($output -join "`n") | ConvertFrom-Json
        $check = @($report.Results | Where-Object { $_.Check -eq 'Share access' })
        $check.Count | Should -Be 1
        $check[0].Status | Should -Be 'Ok' -Because $check[0].Detail
    }

    It 'Remove deletes the share, the account and the sign-in screen entry' {
        Get-SmbMapping -RemotePath $script:Unc -ErrorAction SilentlyContinue | Remove-SmbMapping -Force
        & $script:ScriptPath -Mode Remove -Yes -ShareName $script:Share -UserName $script:User
        $LASTEXITCODE | Should -Be 0
        Get-SmbShare -Name $script:Share -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Get-LocalUser -Name $script:User -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        (Get-ItemProperty -Path $SignInListKey -ErrorAction SilentlyContinue).PSObject.Properties.Name | Should -Not -Contain $script:User
        Test-Path -LiteralPath (Join-Path -Path $script:Folder -ChildPath 'hello.txt') | Should -BeTrue -Because 'Remove never touches the files'
    }
}
