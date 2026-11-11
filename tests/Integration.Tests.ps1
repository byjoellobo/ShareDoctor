#Requires -Version 5.1
<#
    ShareDoctor integration test (Pester 5 or later, -Tag Integration). See SPEC.md section 13.4.

    WARNING: this test MAKES REAL CHANGES to the PC it runs on. It creates the local account
    'sdtest', the share 'SDTest', a saved sign-in, and may set networks to Private and enable
    firewall rules and services. AfterAll always removes the account, the share, the saved
    sign-in, the sign-in screen entry and the temp folder, even after a failure.

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
        $script:Target = $env:COMPUTERNAME
        $script:Qualified = "$env:COMPUTERNAME\$($script:User)"
        $script:Unc = "\\$($script:Target)\$($script:Share)"

        $existing = Get-LocalUser -Name $script:User -ErrorAction SilentlyContinue
        if ($existing -and $existing.Description -ne $AccountTag) {
            throw "An account named '$($script:User)' already exists and ShareDoctor did not create it. Refusing to run."
        }
        if (Get-SmbShare -Name $script:Share -ErrorAction SilentlyContinue) {
            throw "A share named '$($script:Share)' already exists. Remove it before running this test."
        }

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
        # Always clean up, even when a test failed. Only ever delete the account ShareDoctor made.
        & net.exe use $script:Unc /delete /y 2>&1 | Out-Null
        if (Get-SmbShare -Name $script:Share -ErrorAction SilentlyContinue) {
            Remove-SmbShare -Name $script:Share -Force -ErrorAction Continue
        }
        $leftover = Get-LocalUser -Name $script:User -ErrorAction SilentlyContinue
        if ($leftover -and $leftover.Description -eq $AccountTag) { Remove-LocalUser -Name $script:User -ErrorAction Continue }
        & cmdkey.exe "/delete:$($script:Target)" 2>&1 | Out-Null
        Remove-ItemProperty -Path $SignInListKey -Name $script:User -ErrorAction SilentlyContinue
        if ($script:Folder -and (Test-Path -LiteralPath $script:Folder)) { Remove-Item -LiteralPath $script:Folder -Recurse -Force -ErrorAction Continue }
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

    It 'Connect saves the sign-in and the share opens' {
        $connectArguments = @{
            Mode = 'Connect'; Yes = $true; Computer = $script:Target; ShareName = $script:Share
            UserName = $script:User; Password = $script:Password; NoDriveLetter = $true; NoOpen = $true
        }
        & $script:ScriptPath @connectArguments
        $LASTEXITCODE | Should -Be 0
        $access = Test-ShareAccess -Unc $script:Unc
        $access.Code | Should -Be 0 -Because $access.Message
        Test-Path -LiteralPath (Join-Path -Path $script:Unc -ChildPath 'hello.txt') | Should -BeTrue
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
        & $script:ScriptPath -Mode Remove -Yes -ShareName $script:Share -UserName $script:User
        $LASTEXITCODE | Should -Be 0
        Get-SmbShare -Name $script:Share -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Get-LocalUser -Name $script:User -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        (Get-ItemProperty -Path $SignInListKey -ErrorAction SilentlyContinue).PSObject.Properties.Name | Should -Not -Contain $script:User
        Test-Path -LiteralPath (Join-Path -Path $script:Folder -ChildPath 'hello.txt') | Should -BeTrue -Because 'Remove never touches the files'
    }
}
