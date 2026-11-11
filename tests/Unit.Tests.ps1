#Requires -Version 5.1
<#
    ShareDoctor unit tests (Pester 5 or later). See SPEC.md section 13.3.

    Safe on any Windows PC: no admin rights are needed and nothing on this PC changes.
    ShareDoctor.ps1 is dot-sourced, so only its functions load. Every command that could
    change the PC is mocked, and Read-Host is mocked to fail so -Yes can never prompt.

    Run:  Invoke-Pester -Path .\tests\Unit.Tests.ps1 -Output Detailed
#>

BeforeDiscovery {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:SourceFiles = @(Get-ChildItem -Path $repoRoot -Recurse -File -Include '*.ps1', '*.psd1', '*.cmd' |
            Where-Object { $_.FullName -notmatch '[\\/](\.git|dist)[\\/]' } |
            ForEach-Object { @{ Name = $_.FullName.Substring($repoRoot.Length + 1); FullName = $_.FullName } })
}

BeforeAll {
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:ScriptPath = Join-Path -Path $script:RepoRoot -ChildPath 'ShareDoctor.ps1'
    $script:ShellExe = (Get-Process -Id $PID).Path
    . $script:ScriptPath

    # Commands that change something on a PC. All are mocked for every test as a safety net.
    $script:StateChangingCommands = @(
        'New-LocalUser', 'Set-LocalUser', 'Enable-LocalUser', 'Disable-LocalUser', 'Remove-LocalUser',
        'Add-LocalGroupMember', 'Remove-LocalGroupMember',
        'Set-NetConnectionProfile', 'Enable-NetFirewallRule', 'Disable-NetFirewallRule', 'Set-NetFirewallRule', 'New-NetFirewallRule',
        'Set-Service', 'Start-Service', 'Stop-Service',
        'New-SmbShare', 'Remove-SmbShare', 'Set-SmbShare', 'Grant-SmbShareAccess', 'Revoke-SmbShareAccess', 'Block-SmbShareAccess',
        'New-SmbMapping', 'Remove-SmbMapping', 'Set-SmbServerConfiguration', 'Set-SmbClientConfiguration',
        'Enable-WindowsOptionalFeature', 'Disable-WindowsOptionalFeature',
        'New-Item', 'New-ItemProperty', 'Set-ItemProperty', 'Remove-ItemProperty', 'Remove-Item',
        'Start-Process', 'Invoke-Native'
    ) | Where-Object { Get-Command -Name $_ -ErrorAction SilentlyContinue }
    foreach ($command in $script:StateChangingCommands) { Mock -CommandName $command -MockWith {} }

    Mock Read-Host { throw 'Read-Host was called. With -Yes, ShareDoctor must never prompt.' }
    Mock Write-Host {}

    $script:TestPassword = ConvertTo-SecureString -String 'Correct-Horse-9' -AsPlainText -Force
    $script:Qualified = "$env:COMPUTERNAME\shareuser"

    function Invoke-TestMode {
        # Runs Invoke-Main with -Yes plus the given options. Returns { ExitCode, Output }.
        param([Parameter(Mandatory)] [hashtable]$Options)
        $all = @{ Yes = $true }
        foreach ($key in $Options.Keys) { $all[$key] = $Options[$key] }
        return (Invoke-Main -Context (New-RunContext @all))
    }

    function Get-TestFirewallRule([string]$Name, [string]$Profiles, [string]$Enabled = 'True', [string]$Direction = 'Inbound') {
        return [pscustomobject]@{ Name = $Name; Profile = $Profiles; Enabled = $Enabled; Direction = $Direction; DisplayGroup = 'File and Printer Sharing' }
    }

    function Get-TestNetProfile([string]$Category, [int]$Index = 7) {
        return [pscustomobject]@{ Name = 'Home'; InterfaceAlias = 'Wi-Fi'; InterfaceIndex = $Index; NetworkCategory = $Category }
    }

    function Get-TestService([string]$Name, [string]$Status = 'Running', [string]$StartType = 'Automatic') {
        return [pscustomobject]@{ Name = $Name; DisplayName = "$Name service"; Status = $Status; StartType = $StartType }
    }
}

Describe 'Source files' {
    It '<Name> contains only ASCII characters' -ForEach $script:SourceFiles {
        $text = [System.IO.File]::ReadAllText($FullName, [System.Text.Encoding]::GetEncoding('iso-8859-1'))
        $text -match '[^\x00-\x7F]' | Should -BeFalse
    }

    It '<Name> uses CRLF line endings only' -ForEach $script:SourceFiles {
        $text = [System.IO.File]::ReadAllText($FullName, [System.Text.Encoding]::GetEncoding('iso-8859-1'))
        $text -match '(?<!\r)\n' | Should -BeFalse
    }

    It '<Name> parses with no errors' -ForEach ($script:SourceFiles | Where-Object { $_.Name -match '\.ps(d)?1$' }) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($FullName, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'has a semantic version number' {
        $ShareDoctorVersion | Should -Match '^\d+\.\d+\.\d+$'
    }

    It 'keeps the account marker within the 48-character limit Windows puts on descriptions' {
        $AccountTag.Length | Should -BeLessOrEqual 48
        (Get-Command -Name New-LocalUser).Parameters['Description'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateLengthAttribute] } |
            ForEach-Object { $AccountTag.Length | Should -BeLessOrEqual $_.MaxLength }
    }

    It 'contains nothing that weakens SMB security or touches admin accounts' {
        $text = [System.IO.File]::ReadAllText($script:ScriptPath)
        foreach ($forbidden in 'Set-SmbServerConfiguration', 'Set-SmbClientConfiguration', 'Enable-WindowsOptionalFeature',
            'AllowInsecureGuestAuth', 'RequireSecuritySignature', 'EnableSecuritySignature', 'EnableSMB1Protocol',
            'EncryptData', 'NoPassword', 'S-1-5-32-544', 'Invoke-Expression') {
            $text.Contains($forbidden) | Should -BeFalse -Because "ShareDoctor must never use $forbidden"
        }
    }

    It 'never grants share access to Everyone or full control in code' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
        $shareCommands = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in 'New-SmbShare', 'Grant-SmbShareAccess'
            }, $true)
        @($shareCommands).Count | Should -BeGreaterThan 0
        foreach ($command in $shareCommands) {
            $command.Extent.Text | Should -Not -Match 'FullAccess|Everyone|AccessRight\s+Full'
        }
    }
}

Describe 'Command line' {
    It 'loads only functions when dot-sourced' {
        $output = & $script:ShellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ". '$($script:ScriptPath)'; 'loaded'"
        $LASTEXITCODE | Should -Be 0
        $output | Should -Be 'loaded'
    }

    It 'exits with code 2 when -Yes is given without a mode' {
        $null = & $script:ShellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:ScriptPath -Yes
        $LASTEXITCODE | Should -Be 2
    }

    It 'prints only JSON for Diagnose -Json (read-only, real checks)' {
        $output = & $script:ShellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:ScriptPath -Mode Diagnose -Yes -Json
        $LASTEXITCODE | Should -BeIn @(0, 3)
        $report = ($output -join "`n") | ConvertFrom-Json
        $report.Version | Should -Be $ShareDoctorVersion
        $report.ComputerName | Should -Be $env:COMPUTERNAME
        @($report.Results).Count | Should -BeGreaterThan 0
    }
}

Describe 'Get-ErrorAdvice' {
    It 'returns the advice for code <Code>' -ForEach @(
        @{ Code = 0; Text = 'Access works.' }
        @{ Code = 5; Text = 'Access denied: the account used is not allowed into this share or folder. On the PC with the files, run ShareDoctor option 1 (Host) for this folder, then connect with the share account it creates.' }
        @{ Code = 51; Text = 'The other PC cannot be reached for file sharing. Check that it is switched on, on the same network (not a guest Wi-Fi, which usually keeps devices apart), its network is set to Private, and File and Printer Sharing is allowed (Host mode does both). Try the IP address instead of the name. Third-party antivirus firewalls can also block this.' }
        @{ Code = 53; Text = 'The other PC cannot be reached for file sharing. Check that it is switched on, on the same network (not a guest Wi-Fi, which usually keeps devices apart), its network is set to Private, and File and Printer Sharing is allowed (Host mode does both). Try the IP address instead of the name. Third-party antivirus firewalls can also block this.' }
        @{ Code = 1231; Text = 'The other PC cannot be reached for file sharing. Check that it is switched on, on the same network (not a guest Wi-Fi, which usually keeps devices apart), its network is set to Private, and File and Printer Sharing is allowed (Host mode does both). Try the IP address instead of the name. Third-party antivirus firewalls can also block this.' }
        @{ Code = 1232; Text = 'The other PC cannot be reached for file sharing. Check that it is switched on, on the same network (not a guest Wi-Fi, which usually keeps devices apart), its network is set to Private, and File and Printer Sharing is allowed (Host mode does both). Try the IP address instead of the name. Third-party antivirus firewalls can also block this.' }
        @{ Code = 64; Text = 'The connection dropped part-way. Usually third-party antivirus/firewall software or an unstable network.' }
        @{ Code = 67; Text = 'The PC answered, but it has no share with that name. Check the spelling (run Diagnose on that PC to list its shares).' }
        @{ Code = 86; Text = 'Wrong password for that account.' }
        @{ Code = 1219; Text = 'You are already connected to that PC with a different username, and Windows allows only one per PC. Disconnect the old connection (Connect mode offers this) or sign out and back in, then try again.' }
        @{ Code = 1272; Text = 'The other PC only offers guest (no password) access, and this PC refuses guest connections for security. Run ShareDoctor option 1 (Host) on the other PC so it has a proper share account, then connect with that account.' }
        @{ Code = 1326; Text = 'Unknown username or wrong password. Use the share account as PCNAME\username. For a Microsoft account, use the full email address and the account password - a PIN does not work over the network.' }
        @{ Code = 1327; Text = 'Account restriction - most often the account has no password. Windows never allows blank-password accounts over the network. Give it a password, or use the ShareDoctor share account.' }
        @{ Code = 1330; Text = 'The password for that account has expired. Sign in on the PC with the files and set a new one (Host mode can do this).' }
        @{ Code = 1331; Text = 'That account is disabled on the PC with the files. Run Host mode there again to re-enable it.' }
        @{ Code = 1909; Text = 'That account is locked after too many wrong passwords. Wait about 10 minutes, or unlock it on the PC with the files.' }
    ) {
        Get-ErrorAdvice -Code $Code | Should -BeExactly $Text
    }

    It 'returns "Windows error N: message" for an unknown code with a message' {
        Get-ErrorAdvice -Code 9999 -Message 'Something odd' | Should -BeExactly 'Windows error 9999: Something odd'
    }

    It 'returns "Windows error N." for an unknown code without a message' {
        Get-ErrorAdvice -Code 9999 | Should -BeExactly 'Windows error 9999.'
    }
}

Describe 'Get-DefaultShareName' {
    It 'names a drive root after its letter' {
        Get-DefaultShareName -FullPath 'D:\' -IsRoot $true | Should -BeExactly 'DriveD'
        Get-DefaultShareName -FullPath 'e:\' -IsRoot $true | Should -BeExactly 'DriveE'
    }

    It 'removes characters that are not allowed in share names' {
        Get-DefaultShareName -FullPath 'D:\My Media [old]' -IsRoot $false | Should -BeExactly 'My Media old'
        Get-DefaultShareName -FullPath 'D:\a+b=c;d,e' -IsRoot $false | Should -BeExactly 'abcde'
    }

    It 'cuts long names to 80 characters' {
        $name = Get-DefaultShareName -FullPath ('D:\' + ('x' * 100)) -IsRoot $false
        $name.Length | Should -Be 80
    }

    It 'falls back to "Shared" when nothing usable is left' {
        Get-DefaultShareName -FullPath 'D:\[]+=;,' -IsRoot $false | Should -BeExactly 'Shared'
    }
}

Describe 'Test-SharePath' {
    BeforeAll {
        $script:WinDir = Join-Path -Path $TestDrive -ChildPath 'Win'
        $script:WinSibling = Join-Path -Path $TestDrive -ChildPath 'WinApps'
        foreach ($folder in @($script:WinDir, (Join-Path -Path $script:WinDir -ChildPath 'Sub'), $script:WinSibling)) {
            [void][System.IO.Directory]::CreateDirectory($folder)
        }
    }

    It 'rejects a network (UNC) path' {
        $check = Test-SharePath -Path '\\server\share'
        $check.Ok | Should -BeFalse
        $check.Reason | Should -Match 'not a network path'
    }

    It 'rejects a folder that does not exist' {
        $check = Test-SharePath -Path (Join-Path -Path $TestDrive -ChildPath 'missing')
        $check.Ok | Should -BeFalse
        $check.Reason | Should -Match 'Folder not found'
    }

    It 'rejects an empty path' {
        (Test-SharePath -Path '  ').Ok | Should -BeFalse
    }

    It 'rejects the system drive root' {
        $check = Test-SharePath -Path "$env:SystemDrive\"
        $check.Ok | Should -BeFalse
        $check.Reason | Should -Match 'whole Windows drive'
    }

    It 'rejects the system drive given as "C:" without a backslash' {
        (Test-SharePath -Path $env:SystemDrive).Ok | Should -BeFalse
    }

    It 'rejects anything under the Windows folder' {
        $check = Test-SharePath -Path (Join-Path -Path $env:windir -ChildPath 'System32')
        $check.Ok | Should -BeFalse
        $check.Reason | Should -Match 'Windows folder'
        (Test-SharePath -Path $env:windir).Ok | Should -BeFalse
    }

    It 'does not confuse a sibling folder with the Windows folder' {
        (Test-SharePath -Path $script:WinSibling -WindowsDirectory $script:WinDir).Ok | Should -BeTrue
        (Test-SharePath -Path (Join-Path -Path $script:WinDir -ChildPath 'Sub') -WindowsDirectory $script:WinDir).Ok | Should -BeFalse
    }

    It 'accepts a normal folder and resolves its full path' {
        $check = Test-SharePath -Path "  `"$TestDrive`"  "
        $check.Ok | Should -BeTrue
        $check.FullPath | Should -Be (Resolve-Path -LiteralPath $TestDrive).ProviderPath
        $check.IsDriveRoot | Should -BeFalse
    }

    It 'accepts the root of a non-system drive and marks it as a drive root' {
        $check = Test-SharePath -Path "$env:SystemDrive\" -SystemDrive 'Q:' -WindowsDirectory 'Q:\Windows'
        $check.Ok | Should -BeTrue
        $check.IsDriveRoot | Should -BeTrue
    }

    It 'cleans typed paths' {
        ConvertTo-CleanPath -Path 'D:' | Should -BeExactly 'D:\'
        ConvertTo-CleanPath -Path '  "D:\Media"  ' | Should -BeExactly 'D:\Media'
    }
}

Describe 'Name validation' {
    It 'accepts the username "<Name>"' -ForEach @(
        @{ Name = 'shareuser' }, @{ Name = 'share.user' }, @{ Name = 'a' }, @{ Name = ('u' * 20) }, @{ Name = 'share user' }
    ) {
        Test-UserNameValid -Name $Name | Should -BeTrue
    }

    It 'rejects the username "<Name>"' -ForEach @(
        @{ Name = '' }, @{ Name = ' ' }, @{ Name = ('u' * 21) }, @{ Name = 'name.' }, @{ Name = 'pc\bob' }, @{ Name = 'a/b' },
        @{ Name = 'a[b' }, @{ Name = 'a]b' }, @{ Name = 'a:b' }, @{ Name = 'a;b' }, @{ Name = 'a|b' }, @{ Name = 'a=b' },
        @{ Name = 'a,b' }, @{ Name = 'a+b' }, @{ Name = 'a*b' }, @{ Name = 'a?b' }, @{ Name = 'a<b' }, @{ Name = 'a>b' },
        @{ Name = 'bob@home' }, @{ Name = 'a"b' }
    ) {
        Test-UserNameValid -Name $Name | Should -BeFalse
    }

    It 'accepts the share name "<Name>"' -ForEach @(
        @{ Name = 'Media' }, @{ Name = 'My Media' }, @{ Name = 'DriveD' }, @{ Name = ('s' * 80) }, @{ Name = 'Photos [2024]' }
    ) {
        Test-ShareNameValid -Name $Name | Should -BeTrue
    }

    It 'rejects the share name "<Name>"' -ForEach @(
        @{ Name = '' }, @{ Name = '   ' }, @{ Name = ('s' * 81) }, @{ Name = 'a\b' }, @{ Name = 'a/b' }, @{ Name = 'a:b' },
        @{ Name = 'a*b' }, @{ Name = 'a?b' }, @{ Name = 'a"b' }, @{ Name = 'a<b' }, @{ Name = 'a>b' }, @{ Name = 'a|b' }
    ) {
        Test-ShareNameValid -Name $Name | Should -BeFalse
    }
}

Describe 'Password checks' {
    It 'rejects a blank password' {
        Get-PasswordProblem -Password ([securestring]::new()) | Should -Match 'blank'
        Get-PasswordProblem -Password $null | Should -Match 'blank'
    }

    It 'rejects a password containing a double quote' {
        Get-PasswordProblem -Password (ConvertTo-SecureString -String 'bad"pw' -AsPlainText -Force) | Should -Match 'character'
    }

    It 'accepts a normal password' {
        Get-PasswordProblem -Password $script:TestPassword | Should -BeExactly ''
    }

    It 'compares two passwords exactly, including case' {
        $same = ConvertTo-SecureString -String 'Correct-Horse-9' -AsPlainText -Force
        $other = ConvertTo-SecureString -String 'correct-horse-9' -AsPlainText -Force
        Test-SecureStringMatch -First $script:TestPassword -Second $same | Should -BeTrue
        Test-SecureStringMatch -First $script:TestPassword -Second $other | Should -BeFalse
    }
}

Describe 'Get-ElevationArguments' {
    It 'quotes every value and passes the mode' {
        $line = Get-ElevationArguments -ScriptPath 'C:\Tools\ShareDoctor.ps1' -Mode Host -Path 'D:\My Media' -ShareName 'My Media' -UserName 'shareuser'
        $line | Should -BeExactly '-NoProfile -ExecutionPolicy Bypass -File "C:\Tools\ShareDoctor.ps1" -Mode Host -Relaunched -Path "D:\My Media" -ShareName "My Media" -UserName "shareuser"'
    }

    It 'doubles a trailing backslash so it does not escape the closing quote' {
        Get-ElevationArguments -ScriptPath 'C:\x.ps1' -Mode Host -Path 'D:\' | Should -Match '-Path "D:\\\\"'
    }

    It 'passes -ReadOnly and -Yes only when they are set' {
        $with = Get-ElevationArguments -ScriptPath 'C:\x.ps1' -Mode Host -ReadOnly -Yes
        $with | Should -Match ' -ReadOnly'
        $with | Should -Match ' -Yes'
        $without = Get-ElevationArguments -ScriptPath 'C:\x.ps1' -Mode Remove
        $without | Should -Not -Match 'ReadOnly|-Yes|-Path|-ShareName|-UserName'
    }

    It 'has no way to pass a password' {
        (Get-Command -Name Get-ElevationArguments).Parameters.Keys | Should -Not -Contain 'Password'
    }

    It 'refuses values containing a double quote' {
        { Get-ElevationArguments -ScriptPath 'C:\x.ps1' -Mode Host -Path 'D:\a"b' } | Should -Throw
    }
}

Describe 'Error code mapping' {
    It 'maps HResult <HResult> to Windows error <Code>' -ForEach @(
        @{ HResult = 0x80070005; Code = 5 }
        @{ HResult = 0x80070035; Code = 53 }
        @{ HResult = 0x80070043; Code = 67 }
        @{ HResult = 0x800704F8; Code = 1272 }
        @{ HResult = 0x8007052E; Code = 1326 }
    ) {
        $exception = [System.IO.IOException]::new('test failure', [int]$HResult)
        (Get-AccessErrorCode -Exception $exception).Code | Should -Be $Code
    }

    It 'unwraps a MethodInvocationException' {
        $inner = [System.IO.IOException]::new('Logon failure', 0x8007052E)
        $outer = [System.Management.Automation.MethodInvocationException]::new('Exception calling MoveNext', $inner)
        $result = Get-AccessErrorCode -Exception $outer
        $result.Code | Should -Be 1326
        $result.Message | Should -Be 'Logon failure'
    }

    It 'maps UnauthorizedAccessException to 5' {
        (Get-AccessErrorCode -Exception ([System.UnauthorizedAccessException]::new('nope'))).Code | Should -Be 5
    }

    It 'returns -1 and the message for anything else' {
        $result = Get-AccessErrorCode -Exception ([System.InvalidOperationException]::new('odd'))
        $result.Code | Should -Be -1
        $result.Message | Should -Be 'odd'
    }

    It 'Test-ShareAccess returns 0 when the share opens' {
        Mock Invoke-DirectoryProbe {}
        (Test-ShareAccess -Unc '\\PC1\Media').Code | Should -Be 0
    }

    It 'Test-ShareAccess returns the Windows error when it fails' {
        Mock Invoke-DirectoryProbe { throw [System.IO.IOException]::new('The network name cannot be found.', 0x80070043) }
        (Test-ShareAccess -Unc '\\PC1\Nope').Code | Should -Be 67
    }

    It 'reads the error code from "net view" output' {
        Get-NetViewErrorCode -Output 'System error 53 has occurred.' | Should -Be 53
        Get-NetViewErrorCode -Output 'no number here' | Should -Be -1
    }

    It 'maps cancellations to exit code 2 and other failures to 1' {
        Get-FailureExitCode -Exception ([System.OperationCanceledException]::new('x')) | Should -Be 2
        Get-FailureExitCode -Exception ([System.Exception]::new('x', [System.OperationCanceledException]::new('y'))) | Should -Be 2
        Get-FailureExitCode -Exception ([System.InvalidOperationException]::new('x')) | Should -Be 1
    }
}

Describe 'Prompts and -Yes' {
    It 'uses the default without asking when -Yes is set' {
        $context = New-RunContext -Yes
        Read-Answer -Context $context -Prompt 'Share name' -Default 'Media' -Missing 'a share name' | Should -BeExactly 'Media'
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'fails with a cancellation when -Yes is set and there is no default' {
        $context = New-RunContext -Yes
        { Read-Answer -Context $context -Prompt 'Folder' -Missing 'the folder (-Path)' } | Should -Throw -ExceptionType ([System.OperationCanceledException])
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'asks in the administrator window ShareDoctor opened itself' {
        Mock Read-Host { 'D:\Media' }
        $context = New-RunContext -Yes -Relaunched
        Read-Answer -Context $context -Prompt 'Folder' -Missing 'the folder (-Path)' | Should -BeExactly 'D:\Media'
    }

    It 'answers yes to every confirmation with -Yes' {
        Confirm-Step -Context (New-RunContext -Yes) -Question 'Delete?' -DefaultYes $false | Should -BeTrue
    }

    It 'uses the default answer when Enter is pressed' {
        Mock Read-Host { '' }
        Confirm-Step -Context (New-RunContext) -Question 'Continue?' | Should -BeTrue
        Confirm-Step -Context (New-RunContext) -Question 'Delete?' -DefaultYes $false | Should -BeFalse
    }

    It 'waits for Enter before closing the administrator window' {
        Mock Read-Host { '' }
        $null = Invoke-Main -Context (New-RunContext -Mode Diagnose -Yes -Json -Relaunched)
        Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter { "$Prompt" -like '*Press Enter*' }
    }
}

Describe 'Drive letters and usernames' {
    It 'picks the first free letter from Z down, skipping used ones' {
        Select-FreeDriveLetter -Used @('Z', 'y:', 'X') | Should -BeExactly 'W'
        Select-FreeDriveLetter -Used @() | Should -BeExactly 'Z'
    }

    It 'returns nothing when every letter is used' {
        Select-FreeDriveLetter -Used ([char[]]'ZYXWVUTSRQPONMLKJIHGFE' | ForEach-Object { [string]$_ }) | Should -BeExactly ''
    }

    It 'skips drives and mapped letters reported by Windows' {
        Mock Get-UsedDriveLetter { @('C', 'D', 'Z') }
        Get-FreeDriveLetter | Should -BeExactly 'Y'
    }

    It 'normalises a typed drive letter' {
        ConvertTo-DriveLetter -Letter 'm' | Should -BeExactly 'M:'
        ConvertTo-DriveLetter -Letter ' M: ' | Should -BeExactly 'M:'
        { ConvertTo-DriveLetter -Letter 'MM' } | Should -Throw
    }

    It 'turns "<Typed>" into "<Expected>"' -ForEach @(
        @{ Typed = 'bob'; Expected = 'PC1\bob' }
        @{ Typed = '  bob '; Expected = 'PC1\bob' }
        @{ Typed = 'PC1\bob'; Expected = 'PC1\bob' }
        @{ Typed = 'OTHER\bob'; Expected = 'OTHER\bob' }
        @{ Typed = 'a@b.com'; Expected = 'a@b.com' }
    ) {
        Format-ConnectUserName -Typed $Typed -Target 'PC1' | Should -BeExactly $Expected
    }
}

Describe 'Host mode' {
    BeforeAll {
        $script:Folder = Join-Path -Path $TestDrive -ChildPath 'Media'
        [void][System.IO.Directory]::CreateDirectory($script:Folder)
        $script:FolderFull = (Resolve-Path -LiteralPath $script:Folder).ProviderPath

        function Invoke-TestHost([hashtable]$Extra = @{}) {
            $options = @{ Mode = 'Host'; Path = $script:Folder; ShareName = 'Media'; Password = $script:TestPassword }
            foreach ($key in $Extra.Keys) { $options[$key] = $Extra[$key] }
            return (Invoke-TestMode -Options $options)
        }

        Mock Test-IsAdmin { $true }
        Mock Get-LocalUser {}
        Mock Get-SmbShare {}
        Mock Get-NetConnectionProfile { Get-TestNetProfile -Category 'Private' }
        Mock Get-NetFirewallRule {
            Get-TestFirewallRule -Name 'RULE-PRIVATE' -Profiles 'Private' -Enabled 'False'
            Get-TestFirewallRule -Name 'RULE-ANY' -Profiles 'Any' -Enabled 'False'
            Get-TestFirewallRule -Name 'RULE-PUBLIC' -Profiles 'Public' -Enabled 'False'
            Get-TestFirewallRule -Name 'RULE-DOMAIN' -Profiles 'Domain' -Enabled 'False'
        }
        Mock Get-Service { Get-TestService -Name "$Name" }
        Mock Get-NetIPAddress { [pscustomobject]@{ IPAddress = '192.168.1.20' } }
        # Test-Path stays real: it only reads. New-Item and New-ItemProperty are mocked.
        Mock Invoke-Native { [pscustomobject]@{ ExitCode = 0; Output = '' } }
    }

    It 'creates the share account once, with the marker description' {
        (Invoke-TestHost).ExitCode | Should -Be 0
        Should -Invoke New-LocalUser -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'shareuser' -and $Description -eq $AccountTag -and $PasswordNeverExpires -and $AccountNeverExpires -and $UserMayNotChangePassword
        }
    }

    It 'adds the account to the Users group by SID S-1-5-32-545' {
        $null = Invoke-TestHost
        Should -Invoke Add-LocalGroupMember -Times 1 -Exactly -ParameterFilter { "$SID" -eq 'S-1-5-32-545' -and "$Member" -eq 'shareuser' }
    }

    It 'hides the account from the sign-in screen (UserList value 0)' {
        $null = Invoke-TestHost
        Should -Invoke New-ItemProperty -Times 1 -Exactly -ParameterFilter {
            $Path -contains $SignInListKey -and $Name -eq 'shareuser' -and $Value -eq 0 -and "$PropertyType" -eq 'DWord'
        }
    }

    It 'shares the folder with the share account only, never Everyone' {
        $null = Invoke-TestHost
        Should -Invoke New-SmbShare -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Media' -and $Path -eq $script:FolderFull -and (@($ChangeAccess) -join ',') -eq $script:Qualified -and
            -not $ReadAccess -and -not $FullAccess -and -not $NoAccess -and -not (@($ChangeAccess) -match 'Everyone')
        }
        Should -Invoke Grant-SmbShareAccess -Times 0 -Exactly
    }

    It 'gives the account change rights on the folder' {
        $null = Invoke-TestHost
        Should -Invoke Invoke-Native -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'icacls.exe' -and $Arguments[0] -eq $script:FolderFull -and $Arguments[1] -eq '/grant' -and $Arguments[2] -eq "$($script:Qualified):(OI)(CI)M"
        }
    }

    It 'uses read access and RX folder rights with -ReadOnly' {
        $null = Invoke-TestHost -Extra @{ ReadOnly = $true }
        Should -Invoke New-SmbShare -Times 1 -Exactly -ParameterFilter { (@($ReadAccess) -join ',') -eq $script:Qualified -and -not $ChangeAccess }
        Should -Invoke Invoke-Native -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'icacls.exe' -and $Arguments[2] -eq "$($script:Qualified):(OI)(CI)RX" }
    }

    It 'grants access on an existing share for the same folder instead of creating one' {
        Mock Get-SmbShare { [pscustomobject]@{ Name = 'Media'; Path = $script:FolderFull } }
        (Invoke-TestHost).ExitCode | Should -Be 0
        Should -Invoke Grant-SmbShareAccess -Times 1 -Exactly -ParameterFilter { $Name -contains 'Media' -and $AccountName -contains $script:Qualified -and "$AccessRight" -eq 'Change' }
        Should -Invoke New-SmbShare -Times 0 -Exactly
    }

    It 'refuses a share name already used for a different folder, before changing anything' {
        Mock Get-SmbShare { [pscustomobject]@{ Name = 'Media'; Path = 'E:\Other' } }
        (Invoke-TestHost).ExitCode | Should -Be 1
        Should -Invoke New-LocalUser -Times 0 -Exactly
        Should -Invoke New-SmbShare -Times 0 -Exactly
        Should -Invoke Grant-SmbShareAccess -Times 0 -Exactly
    }

    It 'throws when publishing over a share that points somewhere else' {
        Mock Get-SmbShare { [pscustomobject]@{ Name = 'Media'; Path = 'E:\Other' } }
        $folder = [pscustomobject]@{ FullPath = $script:FolderFull }
        $account = [pscustomobject]@{ Name = 'shareuser'; Qualified = $script:Qualified }
        { Publish-Share -Context (New-RunContext -Yes) -Folder $folder -Name 'Media' -Account $account } | Should -Throw '*already exists*'
    }

    It 'sets a Public network to Private' {
        Mock Get-NetConnectionProfile { Get-TestNetProfile -Category 'Public' -Index 12 }
        $null = Invoke-TestHost
        Should -Invoke Set-NetConnectionProfile -Times 1 -Exactly -ParameterFilter { $InterfaceIndex -contains 12 -and "$NetworkCategory" -eq 'Private' }
    }

    It 'leaves a domain network alone' {
        Mock Get-NetConnectionProfile { Get-TestNetProfile -Category 'DomainAuthenticated' }
        $null = Invoke-TestHost
        Should -Invoke Set-NetConnectionProfile -Times 0 -Exactly
    }

    It 'enables only the Private and Any firewall rules of both groups' {
        $null = Invoke-TestHost
        Should -Invoke Get-NetFirewallRule -Times 1 -Exactly -ParameterFilter { $Group -contains '@FirewallAPI.dll,-28502' }
        Should -Invoke Get-NetFirewallRule -Times 1 -Exactly -ParameterFilter { $Group -contains '@FirewallAPI.dll,-32752' }
        Should -Invoke Enable-NetFirewallRule -Times 2 -Exactly -ParameterFilter { (@($Name) -join ',') -eq 'RULE-PRIVATE,RULE-ANY' }
        Should -Invoke Enable-NetFirewallRule -Times 0 -Exactly -ParameterFilter { $Name -contains 'RULE-PUBLIC' -or $Name -contains 'RULE-DOMAIN' }
    }

    It 'sets the sharing services to start automatically and starts them' {
        Mock Get-Service { Get-TestService -Name "$Name" -Status 'Stopped' -StartType 'Manual' }
        (Invoke-TestHost).ExitCode | Should -Be 0
        Should -Invoke Set-Service -Times 3 -Exactly -ParameterFilter { "$StartupType" -eq 'Automatic' }
        foreach ($service in 'LanmanServer', 'FDResPub', 'fdPHost') {
            Should -Invoke Start-Service -Times 1 -Exactly -ParameterFilter { $Name -contains $service }
        }
    }

    It 'treats a service that will not start as a warning, not a failure' {
        Mock Get-Service { Get-TestService -Name "$Name" -Status 'Stopped' }
        Mock Start-Service { throw 'cannot start' }
        (Invoke-TestHost).ExitCode | Should -Be 0
    }

    It 'never touches Windows security settings or other accounts' {
        $null = Invoke-TestHost
        foreach ($command in 'Set-SmbServerConfiguration', 'Set-SmbClientConfiguration', 'Enable-WindowsOptionalFeature') {
            Should -Invoke $command -Times 0 -Exactly
        }
        Should -Invoke Set-LocalUser -Times 0 -Exactly -ParameterFilter { $Name -ne 'shareuser' }
        Should -Invoke Remove-LocalUser -Times 0 -Exactly
    }

    It 'reuses an existing ShareDoctor account, re-enables it and sets the new password' {
        Mock Get-LocalUser { [pscustomobject]@{ Name = 'shareuser'; Enabled = $false; Description = $AccountTag } }
        (Invoke-TestHost).ExitCode | Should -Be 0
        Should -Invoke New-LocalUser -Times 0 -Exactly
        Should -Invoke Enable-LocalUser -Times 1 -Exactly -ParameterFilter { $Name -contains 'shareuser' }
        Should -Invoke Set-LocalUser -Times 1 -Exactly -ParameterFilter { $Name -eq 'shareuser' -and $null -ne $Password }
    }

    It 'keeps the password of an existing account when -Password is not given' {
        Mock Get-LocalUser { [pscustomobject]@{ Name = 'shareuser'; Enabled = $true; Description = $AccountTag } }
        (Invoke-TestHost -Extra @{ Password = $null }).ExitCode | Should -Be 0
        Should -Invoke Set-LocalUser -Times 0 -Exactly
    }

    It 'refuses to take over an account ShareDoctor did not create' {
        Mock Get-LocalUser { [pscustomobject]@{ Name = 'shareuser'; Enabled = $true; Description = 'Someone else' } }
        (Invoke-TestHost).ExitCode | Should -Be 1
        foreach ($command in 'Set-LocalUser', 'Enable-LocalUser', 'New-LocalUser', 'Add-LocalGroupMember', 'New-ItemProperty', 'New-SmbShare') {
            Should -Invoke $command -Times 0 -Exactly
        }
    }

    It 'refuses to use your own account as the share account' {
        (Invoke-TestHost -Extra @{ UserName = $env:USERNAME }).ExitCode | Should -Be 1
        Should -Invoke New-LocalUser -Times 0 -Exactly
        Should -Invoke Set-LocalUser -Times 0 -Exactly
    }

    It 'rejects a blank password' {
        (Invoke-TestHost -Extra @{ Password = [securestring]::new() }).ExitCode | Should -Be 1
        Should -Invoke New-LocalUser -Times 0 -Exactly
    }

    It 'rejects a password with a double quote' {
        (Invoke-TestHost -Extra @{ Password = (ConvertTo-SecureString -String 'a"b' -AsPlainText -Force) }).ExitCode | Should -Be 1
        Should -Invoke New-LocalUser -Times 0 -Exactly
    }

    It 'rejects an invalid username before changing anything' {
        (Invoke-TestHost -Extra @{ UserName = 'bad\name' }).ExitCode | Should -Be 1
        Should -Invoke New-LocalUser -Times 0 -Exactly
    }

    It 'rejects a network path before changing anything' {
        (Invoke-TestHost -Extra @{ Path = '\\server\share' }).ExitCode | Should -Be 1
        Should -Invoke New-LocalUser -Times 0 -Exactly
    }

    It 'exits with code 2, without prompting, when -Yes has no folder' {
        (Invoke-TestHost -Extra @{ Path = '' }).ExitCode | Should -Be 2
        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke New-LocalUser -Times 0 -Exactly
    }

    It 'exits with code 2 when -Yes has no password for a new account' {
        (Invoke-TestHost -Extra @{ Password = $null }).ExitCode | Should -Be 2
        Should -Invoke New-LocalUser -Times 0 -Exactly
    }

    It 'uses the default share name with -Yes' {
        (Invoke-TestHost -Extra @{ ShareName = '' }).ExitCode | Should -Be 0
        Should -Invoke New-SmbShare -Times 1 -Exactly -ParameterFilter { $Name -eq 'Media' }
    }

    It 'returns 1 when the account cannot be hidden from the sign-in screen' {
        Mock New-ItemProperty { throw 'Access is denied' }
        (Invoke-TestHost).ExitCode | Should -Be 1
    }

    It 'asks Windows for admin rights and never passes the password across' {
        Mock Test-IsAdmin { $false }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        (Invoke-TestHost).ExitCode | Should -Be 0
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $Verb -eq 'RunAs' -and $Wait -and "$ArgumentList" -match '-Mode Host -Relaunched' -and
            "$ArgumentList" -match '-Yes' -and "$ArgumentList" -notmatch 'Password|Correct-Horse'
        }
        Should -Invoke New-LocalUser -Times 0 -Exactly
    }

    It 'returns the exit code of the administrator window' {
        Mock Test-IsAdmin { $false }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 2 } }
        (Invoke-TestHost).ExitCode | Should -Be 2
    }

    It 'changes nothing and returns 1 when admin permission is refused' {
        Mock Test-IsAdmin { $false }
        Mock Start-Process { throw [System.InvalidOperationException]::new('The operation was canceled by the user.') }
        (Invoke-TestHost).ExitCode | Should -Be 1
        Should -Invoke New-LocalUser -Times 0 -Exactly
    }
}

Describe 'Connect mode' {
    BeforeAll {
        function Invoke-TestConnect([hashtable]$Extra = @{}) {
            $options = @{ Mode = 'Connect'; Computer = 'PC1'; ShareName = 'Media'; Password = $script:TestPassword; NoOpen = $true }
            foreach ($key in $Extra.Keys) { $options[$key] = $Extra[$key] }
            return (Invoke-TestMode -Options $options)
        }

        Mock Test-IsAdmin { $false }
        Mock Resolve-Target { @('192.168.1.20') }
        Mock Test-Port445 { $true }
        Mock Get-SmbMapping {}
        Mock Invoke-Native { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock Test-ShareAccess { [pscustomobject]@{ Code = 0; Message = '' } }
        Mock Get-FreeDriveLetter { 'Z' }
    }

    It 'saves the sign-in for the target with cmdkey' {
        (Invoke-TestConnect).ExitCode | Should -Be 0
        Should -Invoke Invoke-Native -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'cmdkey.exe' -and $Arguments[0] -eq '/add:PC1' -and $Arguments[1] -eq '/user:PC1\shareuser' -and $Arguments[2] -eq '/pass:Correct-Horse-9'
        }
    }

    It 'keeps an email address or PC\name username as typed' {
        $null = Invoke-TestConnect -Extra @{ UserName = 'bob@example.com' }
        Should -Invoke Invoke-Native -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'cmdkey.exe' -and $Arguments[1] -eq '/user:bob@example.com' }
    }

    It 'removes the saved sign-in after error 1326 with -Yes' {
        Mock Test-ShareAccess { [pscustomobject]@{ Code = 1326; Message = 'Logon failure' } }
        (Invoke-TestConnect).ExitCode | Should -Be 1
        Should -Invoke Invoke-Native -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'cmdkey.exe' -and $Arguments[0] -eq '/delete:PC1' }
        Should -Invoke Invoke-Native -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'net.exe' }
    }

    It 'keeps the saved sign-in for errors that are not about signing in' {
        Mock Test-ShareAccess { [pscustomobject]@{ Code = 67; Message = 'not found' } }
        (Invoke-TestConnect).ExitCode | Should -Be 1
        Should -Invoke Invoke-Native -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'cmdkey.exe' -and $Arguments[0] -like '/delete:*' }
    }

    It 'maps the first free drive letter by default' {
        $null = Invoke-TestConnect
        Should -Invoke Invoke-Native -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'net.exe' -and ($Arguments -join ' ') -eq 'use Z: \\PC1\Media /persistent:yes'
        }
    }

    It 'uses -DriveLetter when given' {
        $null = Invoke-TestConnect -Extra @{ DriveLetter = 'm' }
        Should -Invoke Invoke-Native -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'net.exe' -and $Arguments[1] -eq 'M:' }
        Should -Invoke Get-FreeDriveLetter -Times 0 -Exactly
    }

    It 'maps no drive letter with -NoDriveLetter' {
        $null = Invoke-TestConnect -Extra @{ NoDriveLetter = $true }
        Should -Invoke Invoke-Native -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'net.exe' -and $Arguments[0] -eq 'use' }
    }

    It 'does not open File Explorer with -NoOpen' {
        $null = Invoke-TestConnect
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'opens File Explorer at the new drive without -NoOpen' {
        $null = Invoke-TestConnect -Extra @{ NoOpen = $false }
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'explorer.exe' -and "$ArgumentList" -eq 'Z:\' }
    }

    It 'opens the network path when no drive letter is mapped' {
        $null = Invoke-TestConnect -Extra @{ NoOpen = $false; NoDriveLetter = $true }
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'explorer.exe' -and "$ArgumentList" -eq '\\PC1\Media' }
    }

    It 'stops before saving anything when the PC cannot be found' {
        Mock Resolve-Target { @() }
        (Invoke-TestConnect).ExitCode | Should -Be 1
        Should -Invoke Invoke-Native -Times 0 -Exactly
    }

    It 'stops before saving anything when port 445 is closed' {
        Mock Test-Port445 { $false }
        (Invoke-TestConnect).ExitCode | Should -Be 1
        Should -Invoke Invoke-Native -Times 0 -Exactly
    }

    It 'disconnects old connections to the same PC' {
        Mock Get-SmbMapping { [pscustomobject]@{ LocalPath = ''; RemotePath = '\\PC1\Old' } }
        $null = Invoke-TestConnect
        Should -Invoke Invoke-Native -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'net.exe' -and ($Arguments -join ' ') -eq 'use \\PC1\Old /delete /y' }
    }

    It 'strips backslashes from the typed PC and share names' {
        $null = Invoke-TestConnect -Extra @{ Computer = '\\PC1'; ShareName = '\Media\' }
        Should -Invoke Test-ShareAccess -Times 1 -Exactly -ParameterFilter { $Unc -eq '\\PC1\Media' }
    }

    It 'exits with code 2, without prompting, when -Yes has no PC name' {
        (Invoke-TestConnect -Extra @{ Computer = '' }).ExitCode | Should -Be 2
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'exits with code 2 when -Yes has no password' {
        (Invoke-TestConnect -Extra @{ Password = $null }).ExitCode | Should -Be 2
        Should -Invoke Invoke-Native -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'cmdkey.exe' }
    }

    It 'refuses a blank password' {
        (Invoke-TestConnect -Extra @{ Password = [securestring]::new() }).ExitCode | Should -Be 1
        Should -Invoke Invoke-Native -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'cmdkey.exe' }
    }

    It 'rejects an invalid drive letter before doing anything' {
        (Invoke-TestConnect -Extra @{ DriveLetter = '12' }).ExitCode | Should -Be 1
        Should -Invoke Resolve-Target -Times 0 -Exactly
    }

    It 'stops in an administrator window when the user says no' {
        Mock Test-IsAdmin { $true }
        Mock Read-Host { 'n' }
        (Invoke-TestConnect -Extra @{ Yes = $false }).ExitCode | Should -Be 2
        Should -Invoke Resolve-Target -Times 0 -Exactly
    }
}

Describe 'Diagnose mode' {
    BeforeAll {
        function Invoke-TestDiagnose([hashtable]$Extra = @{}) {
            $options = @{ Mode = 'Diagnose' }
            foreach ($key in $Extra.Keys) { $options[$key] = $Extra[$key] }
            return (Invoke-TestMode -Options $options)
        }

        function Get-TestResult([string]$Area = '', [string]$Status = '') {
            $report = Get-DiagnoseReport -Target $script:DiagnoseTarget -Share $script:DiagnoseShare
            return @($report.Results | Where-Object { (-not $Area -or $_.Area -eq $Area) -and (-not $Status -or $_.Status -eq $Status) })
        }

        $script:DiagnoseTarget = ''
        $script:DiagnoseShare = ''

        Mock Get-CimInstance { [pscustomobject]@{ Caption = 'Microsoft Windows 11 Pro'; BuildNumber = '26100' } } -ParameterFilter { $ClassName -eq 'Win32_OperatingSystem' }
        Mock Get-CimInstance {} -ParameterFilter { $Namespace -eq 'root/SecurityCenter2' }
        Mock Get-NetIPAddress { [pscustomobject]@{ IPAddress = '192.168.1.20' } }
        Mock Get-NetConnectionProfile { Get-TestNetProfile -Category 'Private' }
        Mock Get-NetFirewallRule {
            Get-TestFirewallRule -Name 'IN-PRIVATE' -Profiles 'Private'
            Get-TestFirewallRule -Name 'IN-PUBLIC' -Profiles 'Public' -Enabled 'False'
            Get-TestFirewallRule -Name 'OUT-PRIVATE' -Profiles 'Private' -Enabled 'False' -Direction 'Outbound'
        }
        Mock Get-Service { Get-TestService -Name "$Name" }
        Mock Get-LocalUser { [pscustomobject]@{ Name = $env:USERNAME; PrincipalSource = 'Local'; Enabled = $true; Description = '' } } -ParameterFilter { $Name }
        Mock Get-LocalUser { [pscustomobject]@{ Name = 'shareuser'; Enabled = $true; Description = $AccountTag } } -ParameterFilter { -not $Name }
        Mock Get-ItemProperty { [pscustomobject]@{ shareuser = 0 } }
        Mock Test-IsAdmin { $false }
        Mock Get-SmbShare {}
        Mock Get-SmbShareAccess {}
        Mock Resolve-Target { @('192.168.1.30') }
        Mock Test-Port445 { $true }
        Mock Test-ShareAccess { [pscustomobject]@{ Code = 0; Message = '' } }
        Mock Invoke-Native { [pscustomobject]@{ ExitCode = 0; Output = "Share name  Type  Used as  Comment`nMedia       Disk" } }
    }

    BeforeEach {
        $script:DiagnoseTarget = ''
        $script:DiagnoseShare = ''
    }

    It 'finds no problems on a healthy PC and exits with 0' {
        Get-TestResult -Status 'Fail' | Should -BeNullOrEmpty
        (Invoke-TestDiagnose).ExitCode | Should -Be 0
    }

    It 'reports a Public network as a failure and exits with 3' {
        Mock Get-NetConnectionProfile { Get-TestNetProfile -Category 'Public' }
        @(Get-TestResult -Area 'Network type' -Status 'Fail').Count | Should -Be 1
        (Invoke-TestDiagnose).ExitCode | Should -Be 3
    }

    It 'reports a blocked firewall group as a failure' {
        Mock Get-NetFirewallRule { Get-TestFirewallRule -Name 'IN-PRIVATE' -Profiles 'Private' -Enabled 'False' }
        @(Get-TestResult -Area 'Firewall' -Status 'Fail').Count | Should -Be 2
    }

    It 'warns when a firewall group is only partly allowed' {
        Mock Get-NetFirewallRule {
            Get-TestFirewallRule -Name 'IN-1' -Profiles 'Private'
            Get-TestFirewallRule -Name 'IN-2' -Profiles 'Private, Public' -Enabled 'False'
        }
        @(Get-TestResult -Area 'Firewall' -Status 'Warn').Count | Should -Be 2
    }

    It 'reports a stopped service as a failure' {
        Mock Get-Service { Get-TestService -Name "$Name" -Status 'Stopped' } -ParameterFilter { $Name -contains 'LanmanServer' }
        $failures = @(Get-TestResult -Area 'Services' -Status 'Fail')
        $failures.Count | Should -Be 1
        $failures[0].Check | Should -Be 'LanmanServer'
        (Invoke-TestDiagnose).ExitCode | Should -Be 3
    }

    It 'warns about a third-party firewall' {
        Mock Get-CimInstance { [pscustomobject]@{ displayName = 'Example Antivirus' } } -ParameterFilter { $Namespace -eq 'root/SecurityCenter2' }
        @(Get-TestResult -Area 'Firewall' -Status 'Warn' | Where-Object { $_.Detail -like '*Example Antivirus*' }).Count | Should -Be 1
    }

    It 'warns about a self-assigned 169.254 address' {
        Mock Get-NetIPAddress { [pscustomobject]@{ IPAddress = '169.254.10.20' } }
        @(Get-TestResult -Area 'This PC' -Status 'Warn').Count | Should -Be 1
    }

    It 'warns about signing in with a Microsoft account' {
        Mock Get-LocalUser { [pscustomobject]@{ Name = $env:USERNAME; PrincipalSource = 'MicrosoftAccount' } } -ParameterFilter { $Name }
        @(Get-TestResult -Area 'Your account' -Status 'Warn').Count | Should -Be 1
    }

    It 'warns when a ShareDoctor account shows on the sign-in screen' {
        Mock Get-ItemProperty { throw 'Property shareuser does not exist' }
        $warning = @(Get-TestResult -Area 'ShareDoctor accounts' -Status 'Warn')
        $warning.Count | Should -Be 1
        $warning[0].Fix | Should -Match 'hidden'
    }

    It 'asks for admin rights to list shares when not elevated' {
        @(Get-TestResult -Area 'Folders this PC shares' -Status 'Info')[0].Detail | Should -Match 'administrator'
    }

    It 'warns about a share that only allows Everyone' {
        Mock Test-IsAdmin { $true }
        Mock Get-SmbShare { [pscustomobject]@{ Name = 'Old'; Path = 'D:\Old' } }
        Mock Get-SmbShareAccess { [pscustomobject]@{ AccountName = (Get-EveryoneAccountName); AccessControlType = 'Allow'; AccessRight = 'Full' } }
        @(Get-TestResult -Area 'Folders this PC shares' -Status 'Warn').Count | Should -Be 1
    }

    It 'does not warn about a share that has a real account' {
        Mock Test-IsAdmin { $true }
        Mock Get-SmbShare { [pscustomobject]@{ Name = 'Media'; Path = 'D:\Media' } }
        Mock Get-SmbShareAccess { [pscustomobject]@{ AccountName = $script:Qualified; AccessControlType = 'Allow'; AccessRight = 'Change' } }
        Get-TestResult -Area 'Folders this PC shares' -Status 'Warn' | Should -BeNullOrEmpty
    }

    It 'explains a failed share access with its advice' {
        Mock Test-ShareAccess { [pscustomobject]@{ Code = 1272; Message = 'guest' } }
        $script:DiagnoseTarget = 'PC1'
        $script:DiagnoseShare = 'Media'
        $failure = @(Get-TestResult -Status 'Fail')
        $failure.Count | Should -Be 1
        $failure[0].Check | Should -Be 'Share access'
        $failure[0].Fix | Should -BeExactly (Get-ErrorAdvice -Code 1272)
    }

    It 'explains a failed share list using the code from net view' {
        Mock Invoke-Native { [pscustomobject]@{ ExitCode = 2; Output = 'System error 53 has occurred.' } }
        $script:DiagnoseTarget = 'PC1'
        $failure = @(Get-TestResult -Status 'Fail')
        $failure[0].Check | Should -Be 'Share list'
        $failure[0].Fix | Should -BeExactly (Get-ErrorAdvice -Code 53)
    }

    It 'reports a name that cannot be found' {
        Mock Resolve-Target { @() }
        $script:DiagnoseTarget = 'NOPE'
        @(Get-TestResult -Status 'Fail')[0].Check | Should -Be 'Name lookup'
    }

    It 'keeps going when one check breaks' {
        Mock Get-NetConnectionProfile { throw 'boom' }
        $results = @(Get-TestResult)
        @($results | Where-Object { $_.Area -eq 'Network type' -and $_.Status -eq 'Info' }).Count | Should -Be 1
        @($results | Where-Object { $_.Area -eq 'Services' }).Count | Should -Be 3
    }

    It 'lists each fix once in the summary' {
        Mock Get-Service { Get-TestService -Name "$Name" -Status 'Stopped' }
        $report = Get-DiagnoseReport
        $fixes = @(Get-DiagnoseFix -Report $report)
        $fixes.Count | Should -Be 3
        @($fixes | Select-Object -Unique).Count | Should -Be 3
    }

    It 'prints JSON that parses with ConvertFrom-Json' {
        $result = Invoke-TestDiagnose -Extra @{ Json = $true; Computer = 'PC1'; ShareName = 'Media' }
        $result.ExitCode | Should -Be 0
        $report = $result.Output | ConvertFrom-Json
        $report.Version | Should -Be $ShareDoctorVersion
        $report.ComputerName | Should -Be $env:COMPUTERNAME
        $report.OsCaption | Should -Be 'Microsoft Windows 11 Pro'
        $report.OsBuild | Should -Be '26100'
        @($report.Results).Count | Should -BeGreaterThan 5
        foreach ($item in $report.Results) {
            $item.PSObject.Properties.Name | Should -Be @('Area', 'Check', 'Status', 'Detail', 'Fix')
            $item.Status | Should -BeIn @('Ok', 'Warn', 'Fail', 'Info')
        }
        @($report.Results | Where-Object { $_.Check -eq 'Share access' }).Status | Should -Be 'Ok'
    }

    It 'writes no console text in JSON mode' {
        $null = Invoke-TestDiagnose -Extra @{ Json = $true }
        Should -Invoke Write-Host -Times 0 -Exactly
    }

    It 'exits with 3 in JSON mode when something fails' {
        Mock Get-NetConnectionProfile { Get-TestNetProfile -Category 'Public' }
        (Invoke-TestDiagnose -Extra @{ Json = $true }).ExitCode | Should -Be 3
    }

    It 'never calls a command that changes the PC (at run time)' {
        Mock Test-IsAdmin { $true }
        Mock Get-SmbShare { [pscustomobject]@{ Name = 'Media'; Path = 'D:\Media' } }
        Mock Get-NetConnectionProfile { Get-TestNetProfile -Category 'Public' }
        Mock Get-Service { Get-TestService -Name "$Name" -Status 'Stopped' -StartType 'Disabled' }
        $null = Invoke-TestDiagnose -Extra @{ Computer = 'PC1'; ShareName = 'Media' }
        $null = Invoke-TestDiagnose -Extra @{ Computer = 'PC1' }
        $null = Invoke-TestDiagnose
        foreach ($command in ($script:StateChangingCommands | Where-Object { $_ -ne 'Invoke-Native' })) {
            Should -Invoke $command -Times 0 -Exactly
        }
        Should -Invoke Invoke-Native -Times 0 -Exactly -ParameterFilter { -not ($FilePath -eq 'net.exe' -and $Arguments[0] -eq 'view') }
    }

    It 'never calls a command that changes the PC (static check of everything Diagnose can reach)' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
        $functions = @{}
        foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            $functions[$definition.Name] = $definition
        }
        $visited = @{}
        $pending = [System.Collections.Generic.Queue[string]]::new()
        $pending.Enqueue('Invoke-DiagnoseMode')
        $called = [System.Collections.Generic.List[string]]::new()
        while ($pending.Count -gt 0) {
            $name = $pending.Dequeue()
            if ($visited.ContainsKey($name)) { continue }
            $visited[$name] = $true
            foreach ($command in $functions[$name].Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                $commandName = $command.GetCommandName()
                if (-not $commandName) { continue }
                $called.Add($commandName)
                if ($functions.ContainsKey($commandName)) { $pending.Enqueue($commandName) }
            }
        }
        $visited.Keys | Should -Contain 'Get-ConnectionCheck'
        $forbidden = '^(Set|New|Enable|Disable|Remove|Grant|Add|Start|Stop|Restart|Clear|Revoke|Block|Unblock|Install|Uninstall|Register|Unregister|Rename|Move|Copy|Mount|Dismount|Disconnect|Reset|Update|Publish|Initialize|Hide|Save|Export)-'
        @($called | Where-Object { $_ -match $forbidden } | Select-Object -Unique) | Should -BeNullOrEmpty
    }
}

Describe 'Remove mode' {
    BeforeAll {
        function Invoke-TestRemove([hashtable]$Extra = @{}) {
            $options = @{ Mode = 'Remove'; ShareName = 'Media' }
            foreach ($key in $Extra.Keys) { $options[$key] = $Extra[$key] }
            return (Invoke-TestMode -Options $options)
        }

        Mock Test-IsAdmin { $true }
        Mock Get-SmbShare { [pscustomobject]@{ Name = 'Media'; Path = 'D:\Media' } } -ParameterFilter { $Name -contains 'Media' }
        Mock Get-SmbShare {} -ParameterFilter { -not $Name }
        Mock Get-SmbShareAccess {}
        Mock Get-LocalUser { [pscustomobject]@{ Name = 'shareuser'; Enabled = $true; Description = $AccountTag } }
        Mock Invoke-Native { [pscustomobject]@{ ExitCode = 0; Output = '' } }
    }

    It 'stops sharing and removes the folder permission' {
        (Invoke-TestRemove).ExitCode | Should -Be 0
        Should -Invoke Remove-SmbShare -Times 1 -Exactly -ParameterFilter { $Name -contains 'Media' -and $Force }
        Should -Invoke Invoke-Native -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'icacls.exe' -and ($Arguments -join '|') -eq "D:\Media|/remove:g|$($script:Qualified)"
        }
    }

    It 'deletes the share account and its UserList value when the marker matches' {
        $null = Invoke-TestRemove
        Should -Invoke Remove-LocalUser -Times 1 -Exactly -ParameterFilter { $Name -contains 'shareuser' }
        Should -Invoke Remove-ItemProperty -Times 1 -Exactly -ParameterFilter { $Path -contains $SignInListKey -and $Name -contains 'shareuser' }
    }

    It 'never deletes an account without the marker' {
        Mock Get-LocalUser { [pscustomobject]@{ Name = 'shareuser'; Enabled = $true; Description = 'My own account' } }
        $null = Invoke-TestRemove
        Should -Invoke Remove-LocalUser -Times 0 -Exactly
        Should -Invoke Remove-ItemProperty -Times 0 -Exactly
    }

    It 'keeps the share account while another share still uses it' {
        Mock Get-SmbShare { [pscustomobject]@{ Name = 'Photos'; Path = 'D:\Photos' } } -ParameterFilter { -not $Name }
        Mock Get-SmbShareAccess { [pscustomobject]@{ AccountName = $script:Qualified; AccessControlType = 'Allow'; AccessRight = 'Change' } }
        $null = Invoke-TestRemove
        Should -Invoke Remove-LocalUser -Times 0 -Exactly
    }

    It 'returns 1 for a share that does not exist, and still offers to delete the account' {
        Mock Get-SmbShare {} -ParameterFilter { $Name -contains 'Media' }
        (Invoke-TestRemove).ExitCode | Should -Be 1
        Should -Invoke Remove-SmbShare -Times 0 -Exactly
        Should -Invoke Remove-LocalUser -Times 1 -Exactly
    }

    It 'exits with code 2, without prompting, when -Yes has no share name' {
        (Invoke-TestRemove -Extra @{ ShareName = '' }).ExitCode | Should -Be 2
        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke Remove-SmbShare -Times 0 -Exactly
    }

    It 'asks Windows for admin rights when not elevated' {
        Mock Test-IsAdmin { $false }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        $null = Invoke-TestRemove
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $Verb -eq 'RunAs' -and "$ArgumentList" -match '-Mode Remove -Relaunched' }
        Should -Invoke Remove-SmbShare -Times 0 -Exactly
    }
}

Describe 'Menu' {
    It 'exits with code 2 when -Yes is given without a mode' {
        (Invoke-TestMode -Options @{ Mode = 'Menu' }).ExitCode | Should -Be 2
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'shows the version and asks again after an invalid choice' {
        $script:MenuAnswers = [System.Collections.Queue]::new()
        $script:MenuAnswers.Enqueue('x')
        $script:MenuAnswers.Enqueue('q')
        Mock Read-Host { $script:MenuAnswers.Dequeue() }
        (Invoke-Main -Context (New-RunContext)).ExitCode | Should -Be 0
        Should -Invoke Read-Host -Times 2 -Exactly
        Should -Invoke Write-Host -ParameterFilter { "$Object" -eq "ShareDoctor $ShareDoctorVersion - Windows file sharing helper" }
    }
}
