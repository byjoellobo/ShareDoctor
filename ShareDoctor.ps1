<#
.SYNOPSIS
    ShareDoctor - make Windows 10/11 network file sharing work without disabling security,
    and explain in plain words why access is denied.

.DESCRIPTION
    Current Windows versions refuse password-less (guest) access to shared folders, so
    "turn off password protected sharing" no longer works and you just get "Access denied".
    ShareDoctor works with those protections instead of against them: the PC with the files
    gets a hidden, password-protected share account, the other PCs save that account's
    password once, and any failure is explained in plain words.

    Modes
      Menu      Interactive menu (the default).
      Host      Run on the PC that has the files. Needs admin; asks Windows for permission.
      Connect   Run on the PC that wants the files, in a normal (not admin) window.
      Diagnose  Read-only check of this PC and, optionally, another PC. Changes nothing.
      Remove    Run on the PC that has the files to stop sharing a folder.

    Exit codes: 0 success, 1 error, 2 cancelled (or a required value was missing with -Yes),
    3 Diagnose found at least one problem.

.PARAMETER Mode
    Menu, Host, Connect, Diagnose or Remove. Default: Menu.
.PARAMETER Path
    Host: the folder to share.
.PARAMETER ShareName
    The share name other PCs see.
.PARAMETER UserName
    The share account's name. Default: shareuser.
.PARAMETER Password
    The share account's password as a SecureString, for automation. Asked for if missing.
.PARAMETER Computer
    Connect and Diagnose: the name or IP address of the PC that has the files.
.PARAMETER DriveLetter
    Connect: the drive letter to map, for example M.
.PARAMETER NoDriveLetter
    Connect: do not map a drive letter.
.PARAMETER NoOpen
    Connect: do not open File Explorer at the end.
.PARAMETER ReadOnly
    Host: the share account can read files but not change them.
.PARAMETER Yes
    Answer yes to every question and never prompt. A missing required value exits with code 2.
.PARAMETER Json
    Diagnose: print the results as JSON instead of text.
.PARAMETER Relaunched
    Internal: set when ShareDoctor re-launches itself as administrator.

.EXAMPLE
    .\ShareDoctor.ps1
    Shows the interactive menu.

.EXAMPLE
    .\ShareDoctor.ps1 -Mode Host -Path 'D:\Media' -ShareName Media

.EXAMPLE
    .\ShareDoctor.ps1 -Mode Connect -Computer OFFICE-PC -ShareName Media -DriveLetter M

.EXAMPLE
    .\ShareDoctor.ps1 -Mode Diagnose -Computer OFFICE-PC -ShareName Media -Json
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Host', 'Connect', 'Diagnose', 'Remove')]
    [string]$Mode = 'Menu',
    [string]$Path,
    [string]$ShareName,
    [string]$UserName = 'shareuser',
    [securestring]$Password,
    [string]$Computer,
    [string]$DriveLetter,
    [switch]$NoDriveLetter,
    [switch]$NoOpen,
    [switch]$ReadOnly,
    [switch]$Yes,
    [switch]$Json,
    [switch]$Relaunched
)

$ShareDoctorVersion = '0.2.0'

# Firewall rule groups by their language-independent resource ids.
$FwGroupFileSharing = '@FirewallAPI.dll,-28502'   # File and Printer Sharing
$FwGroupDiscovery = '@FirewallAPI.dll,-32752'     # Network Discovery

# Marks the accounts ShareDoctor created. Remove mode only deletes accounts carrying it.
# Windows limits account descriptions to 48 characters.
$AccountTag = 'File sharing account (created by ShareDoctor)'

# Accounts listed here with the value 0 are not shown on the Windows sign-in screen.
$SignInListKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'

$UsersGroupSid = 'S-1-5-32-545'   # built-in Users group, the same in every display language
$EveryoneSid = 'S-1-1-0'

# Error codes that mean the sign-in itself was refused, so the saved password is suspect.
$SignInErrorCodes = @(5, 86, 1326, 1327, 1330, 1331, 1909)

#region ---------- output ----------

function Split-TextLine([string]$Text, [int]$Width) {
    # Word-wraps text into lines of at most $Width characters. Words longer than that stay whole.
    $lines = @()
    foreach ($paragraph in ("$Text" -split "`r?`n")) {
        if ($paragraph.Length -le $Width) { $lines += $paragraph; continue }
        $indent = [regex]::Match($paragraph, '^\s*').Value
        $current = ''
        foreach ($word in ($paragraph.Trim() -split ' ' | Where-Object { $_ })) {
            if (-not $current) { $current = $indent + $word }
            elseif (($current.Length + 1 + $word.Length) -le $Width) { $current += " $word" }
            else { $lines += $current; $current = $indent + $word }
        }
        $lines += $current
    }
    return $lines
}

function Get-ConsoleWidth {
    try {
        $width = $Host.UI.RawUI.WindowSize.Width
        if ($width -ge 40) { return [int]$width }
    } catch {
        Write-Verbose 'No console window size is available.'
    }
    return 120
}

function Write-Wrapped([string]$Prefix, [string]$Text, [string]$Color = '') {
    # Writes text after a prefix such as "  [ OK ] ", wrapping long lines under the text.
    $lines = @(Split-TextLine -Text $Text -Width ((Get-ConsoleWidth) - $Prefix.Length - 1))
    $indent = ' ' * $Prefix.Length
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $lead = if ($i -eq 0) { $Prefix } else { $indent }
        if ($Color) { Write-Host "$lead$($lines[$i])" -ForegroundColor $Color } else { Write-Host "$lead$($lines[$i])" }
    }
}

function Write-Step([string]$Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Wrapped -Prefix '  [ OK ] ' -Text $Text -Color 'Green' }
function Write-Warn([string]$Text) { Write-Wrapped -Prefix '  [WARN] ' -Text $Text -Color 'Yellow' }
function Write-Bad([string]$Text) { Write-Wrapped -Prefix '  [FAIL] ' -Text $Text -Color 'Red' }
function Write-Info([string]$Text) { Write-Wrapped -Prefix '         ' -Text $Text }

#endregion

#region ---------- run context and input ----------

function New-RunContext {
    # Collects the command-line options into one object that every mode receives.
    [CmdletBinding()]
    param(
        [ValidateSet('Menu', 'Host', 'Connect', 'Diagnose', 'Remove')]
        [string]$Mode = 'Menu',
        [string]$Path = '',
        [string]$ShareName = '',
        [string]$UserName = 'shareuser',
        [securestring]$Password,
        [string]$Computer = '',
        [string]$DriveLetter = '',
        [switch]$NoDriveLetter,
        [switch]$NoOpen,
        [switch]$ReadOnly,
        [switch]$Yes,
        [switch]$Json,
        [switch]$Relaunched
    )
    return [pscustomobject]@{
        Mode          = $Mode
        Path          = "$Path"
        ShareName     = "$ShareName"
        UserName      = "$UserName"
        Password      = $Password
        Computer      = "$Computer"
        DriveLetter   = "$DriveLetter"
        NoDriveLetter = [bool]$NoDriveLetter
        NoOpen        = [bool]$NoOpen
        ReadOnly      = [bool]$ReadOnly
        Yes           = [bool]$Yes
        Json          = [bool]$Json
        Relaunched    = [bool]$Relaunched
    }
}

function Test-NoPrompt {
    # -Yes means "never ask". The administrator window ShareDoctor opens for itself is the
    # one exception: the user is right there, and passwords are never passed across to it.
    param([Parameter(Mandatory)] $Context)
    return [bool]($Context.Yes -and -not $Context.Relaunched)
}

function Get-CancelError([string]$Message = 'Cancelled. Nothing was changed.') {
    return [System.OperationCanceledException]::new($Message)
}

function Get-MissingInputError([string]$Missing) {
    return (Get-CancelError -Message "ShareDoctor needs $Missing. With -Yes it never asks questions, so add it to the command line.")
}

function Confirm-Step {
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string]$Question,
        [bool]$DefaultYes = $true
    )
    if ($Context.Yes) { return $true }
    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    $answer = Read-Host "  $Question $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultYes }
    return $answer.Trim().ToLowerInvariant().StartsWith('y')
}

function Read-OptionalText([string]$Prompt) {
    $answer = Read-Host "  $Prompt"
    if ($null -eq $answer) { return '' }
    return $answer.Trim()
}

function Read-Answer {
    # Asks for a value. With -Yes it returns the default, or fails if there is none.
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string]$Prompt,
        [string]$Default = '',
        [Parameter(Mandatory)] [string]$Missing
    )
    if ($Context.Yes -and $Default) { return $Default }
    if (Test-NoPrompt -Context $Context) { throw (Get-MissingInputError -Missing $Missing) }
    $label = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
    $answer = Read-OptionalText -Prompt $label
    if (-not $answer) { return $Default }
    return $answer
}

function Read-Secret {
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string]$Prompt,
        [Parameter(Mandatory)] [string]$Missing
    )
    if (Test-NoPrompt -Context $Context) { throw (Get-MissingInputError -Missing $Missing) }
    return (Read-Host "  $Prompt" -AsSecureString)
}

#endregion

#region ---------- pure helpers (no side effects) ----------

function Get-ErrorAdvice([int]$Code, [string]$Message = '') {
    switch ($Code) {
        0 { return 'Access works.' }
        5 { return 'Access denied: the account used is not allowed into this share or folder. On the PC with the files, run ShareDoctor option 1 (Host) for this folder, then connect with the share account it creates.' }
        { $_ -in 51, 53, 1231, 1232 } {
            return 'The other PC cannot be reached for file sharing. Check that it is switched on, on the same network (not a guest Wi-Fi, which usually keeps devices apart), its network is set to Private, and File and Printer Sharing is allowed (Host mode does both). Try the IP address instead of the name. Third-party antivirus firewalls can also block this.'
        }
        64 { return 'The connection dropped part-way. Usually third-party antivirus/firewall software or an unstable network.' }
        67 { return 'The PC answered, but it has no share with that name. Check the spelling (run Diagnose on that PC to list its shares).' }
        86 { return 'Wrong password for that account.' }
        1219 { return 'You are already connected to that PC with a different username, and Windows allows only one per PC. Disconnect the old connection (Connect mode offers this) or sign out and back in, then try again.' }
        1272 { return 'The other PC only offers guest (no password) access, and this PC refuses guest connections for security. Run ShareDoctor option 1 (Host) on the other PC so it has a proper share account, then connect with that account.' }
        1326 { return 'Unknown username or wrong password. Use the share account as PCNAME\username. For a Microsoft account, use the full email address and the account password - a PIN does not work over the network.' }
        1327 { return 'Account restriction - most often the account has no password. Windows never allows blank-password accounts over the network. Give it a password, or use the ShareDoctor share account.' }
        1330 { return 'The password for that account has expired. Sign in on the PC with the files and set a new one (Host mode can do this).' }
        1331 { return 'That account is disabled on the PC with the files. Run Host mode there again to re-enable it.' }
        1909 { return 'That account is locked after too many wrong passwords. Wait about 10 minutes, or unlock it on the PC with the files.' }
        default {
            if ($Message) { return "Windows error $Code`: $Message" }
            return "Windows error $Code."
        }
    }
}

function Get-DefaultShareName([string]$FullPath, [bool]$IsRoot) {
    if ($IsRoot) { return 'Drive' + $FullPath.Substring(0, 1).ToUpperInvariant() }
    $leaf = Split-Path -Path $FullPath -Leaf
    $clean = ($leaf -replace '[\\/:*?"<>|\[\]+=;,]', '').Trim()
    if ($clean.Length -gt 80) { $clean = $clean.Substring(0, 80).Trim() }
    if (-not $clean) { return 'Shared' }
    return $clean
}

function Test-ShareNameValid([string]$Name) {
    return [bool]($Name -match '^[^\\/:*?"<>|]{1,80}$' -and $Name.Trim().Length -gt 0)
}

function Test-UserNameValid([string]$Name) {
    if ($Name -notmatch '^[^\\/\[\]:;|=,+*?<>@"]{1,20}$') { return $false }
    if ($Name.EndsWith('.')) { return $false }
    return ($Name.Trim().Length -gt 0)
}

function ConvertTo-CleanPath([string]$Path) {
    # Trims spaces and quotes, and turns "D:" into "D:\".
    $clean = "$Path".Trim().Trim('"').Trim()
    if ($clean -match '^[A-Za-z]:$') { $clean += '\' }
    return $clean
}

function Get-PathCheck([bool]$Ok, [string]$Reason = '', [string]$FullPath = '', [bool]$IsDriveRoot = $false) {
    return [pscustomobject]@{ Ok = $Ok; Reason = $Reason; FullPath = $FullPath; IsDriveRoot = $IsDriveRoot }
}

function Test-SharePath {
    # Checks a folder can safely be shared. Returns { Ok, Reason, FullPath, IsDriveRoot }.
    param(
        [string]$Path,
        [string]$SystemDrive = $env:SystemDrive,
        [string]$WindowsDirectory = $env:windir
    )
    $candidate = ConvertTo-CleanPath -Path $Path
    $networkReason = 'Pick a folder on a drive inside this PC, not a network path.'
    if (-not $candidate) { return (Get-PathCheck -Ok $false -Reason 'Type the full path of a folder, for example D:\Media.') }
    if ($candidate.StartsWith('\\')) { return (Get-PathCheck -Ok $false -Reason $networkReason) }
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { return (Get-PathCheck -Ok $false -Reason "Folder not found: $candidate") }

    $full = (Resolve-Path -LiteralPath $candidate).ProviderPath
    if ($full -notmatch '^[A-Za-z]:\\') { return (Get-PathCheck -Ok $false -Reason $networkReason) }
    $root = [System.IO.Path]::GetPathRoot($full)
    try {
        if ([System.IO.DriveInfo]::new($root).DriveType -eq [System.IO.DriveType]::Network) { return (Get-PathCheck -Ok $false -Reason $networkReason) }
    } catch {
        Write-Verbose "Could not read the drive type of $root`: $($_.Exception.Message)"
    }

    $trimmed = $full.TrimEnd('\')
    $isRoot = ($root.TrimEnd('\') -eq $trimmed)
    $systemRoot = "$SystemDrive".TrimEnd('\')
    if ($isRoot -and $systemRoot -and ($trimmed -eq $systemRoot)) {
        return (Get-PathCheck -Ok $false -Reason "Sharing the whole Windows drive ($systemRoot) would expose system files. Pick a folder instead, for example $systemRoot\Shared.")
    }
    $windows = "$WindowsDirectory".TrimEnd('\')
    if ($windows -and ($trimmed -eq $windows -or $trimmed.StartsWith("$windows\", [System.StringComparison]::OrdinalIgnoreCase))) {
        return (Get-PathCheck -Ok $false -Reason 'Sharing the Windows folder is not allowed. Pick another folder.')
    }
    return (Get-PathCheck -Ok $true -FullPath $full -IsDriveRoot $isRoot)
}

function ConvertTo-Plain([securestring]$Secure) {
    # Only used for validation and for the one cmdkey call. Callers clear the result.
    if ($null -eq $Secure) { return '' }
    return [System.Net.NetworkCredential]::new('', $Secure).Password
}

function Get-PasswordProblem([securestring]$Password) {
    # Returns '' when the password is usable, otherwise the reason it is not.
    $plain = ConvertTo-Plain -Secure $Password
    try {
        if ([string]::IsNullOrEmpty($plain)) { return 'Windows never allows blank passwords over the network. Please choose one.' }
        if ($plain.Contains('"')) { return 'Please avoid the " character - it breaks saving the password on the other PCs.' }
        return ''
    } finally {
        $plain = $null
    }
}

function Test-SecureStringMatch([securestring]$First, [securestring]$Second) {
    $a = ConvertTo-Plain -Secure $First
    $b = ConvertTo-Plain -Secure $Second
    try {
        return ($a -ceq $b)
    } finally {
        $a = $null
        $b = $null
    }
}

function Format-QuotedArgument([string]$Value) {
    if ($Value.Contains('"')) { throw [System.ArgumentException]::new("This value cannot contain a double quote: $Value") }
    # Backslashes right before the closing quote would escape it ("D:\" ends up as D:"), so double them.
    return '"' + [regex]::Replace($Value, '(\\+)$', '$1$1') + '"'
}

function Get-ElevationArguments {
    # Builds the command line for the administrator window. The password is never passed across.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Name fixed by SPEC.md section 9.0.')]
    param(
        [Parameter(Mandatory)] [string]$ScriptPath,
        [Parameter(Mandatory)] [ValidateSet('Host', 'Remove')] [string]$Mode,
        [string]$Path = '',
        [string]$ShareName = '',
        [string]$UserName = '',
        [switch]$ReadOnly,
        [switch]$Yes
    )
    $parts = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Format-QuotedArgument -Value $ScriptPath), '-Mode', $Mode, '-Relaunched')
    if ($Path) { $parts += @('-Path', (Format-QuotedArgument -Value $Path)) }
    if ($ShareName) { $parts += @('-ShareName', (Format-QuotedArgument -Value $ShareName)) }
    if ($UserName) { $parts += @('-UserName', (Format-QuotedArgument -Value $UserName)) }
    if ($ReadOnly) { $parts += '-ReadOnly' }
    if ($Yes) { $parts += '-Yes' }
    return ($parts -join ' ')
}

function Format-ConnectUserName([string]$Typed, [string]$Target) {
    # "bob" becomes "TARGET\bob"; "PC\bob" and "bob@example.com" stay as they are.
    $name = "$Typed".Trim()
    if ($name -match '[\\@]') { return $name }
    return "$Target\$name"
}

function ConvertTo-DriveLetter([string]$Letter) {
    $clean = "$Letter".Trim().TrimEnd(':')
    if ($clean -notmatch '^[A-Za-z]$') { throw "'$Letter' is not a drive letter. Use a single letter such as M." }
    return $clean.ToUpperInvariant() + ':'
}

function Select-FreeDriveLetter([string[]]$Used = @()) {
    # First free letter from Z down to E. Returns '' when none is free.
    $taken = @($Used | ForEach-Object { "$_".Trim().TrimEnd(':').ToUpperInvariant() })
    foreach ($letter in [char[]]'ZYXWVUTSRQPONMLKJIHGFE') {
        if ($taken -notcontains [string]$letter) { return [string]$letter }
    }
    return ''
}

function Get-NetViewErrorCode([string]$Output) {
    # The one allowed text fallback (SPEC.md section 6): the first number in "net view" output.
    if ($Output -match '(\d{1,5})') { return [int]$Matches[1] }
    return -1
}

function Get-AccessErrorCode([System.Exception]$Exception) {
    # Turns an exception into a Windows error code, independent of the display language.
    $e = $Exception
    while ($e.InnerException -and ($e -is [System.Management.Automation.RuntimeException])) { $e = $e.InnerException }
    $hr = $e.HResult
    $code = -1
    if (($hr -band 0xFFFF0000) -eq 0x80070000) { $code = $hr -band 0xFFFF }
    elseif ($e -is [System.UnauthorizedAccessException]) { $code = 5 }
    return [pscustomobject]@{ Code = $code; Message = $e.Message }
}

function Get-CheckResult {
    param(
        [Parameter(Mandatory)] [string]$Area,
        [Parameter(Mandatory)] [string]$Check,
        [Parameter(Mandatory)] [ValidateSet('Ok', 'Warn', 'Fail', 'Info')] [string]$Status,
        [Parameter(Mandatory)] [string]$Detail,
        [string]$Fix = ''
    )
    return [pscustomobject]@{ Area = $Area; Check = $Check; Status = $Status; Detail = $Detail; Fix = $Fix }
}

function Get-DiagnoseFix($Report) {
    return @($Report.Results | Where-Object { $_.Status -in 'Fail', 'Warn' -and $_.Fix } | ForEach-Object { $_.Fix } | Select-Object -Unique)
}

function Get-DiagnoseExitCode($Report) {
    if (@($Report.Results | Where-Object { $_.Status -eq 'Fail' }).Count -gt 0) { return 3 }
    return 0
}

function ConvertTo-DiagnoseJson($Report) {
    return ($Report | ConvertTo-Json -Depth 5)
}

#endregion

#region ---------- system helpers ----------

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Native {
    # Runs a native command and returns { ExitCode, Output }.
    # Windows PowerShell 5.1 turns native stderr into terminating errors under 'Stop'.
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [string[]]$Arguments = @()
    )
    if (-not (Get-Command -Name $FilePath -CommandType Application -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ ExitCode = -1; Output = "$FilePath was not found on this PC." }
    }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $FilePath @Arguments 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ ExitCode = $code; Output = (@($output) -join "`n").Trim() }
}

function Invoke-Elevated {
    # Re-runs ShareDoctor in an administrator window and returns that window's exit code.
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [ValidateSet('Host', 'Remove')] [string]$Mode
    )
    $exe = (Get-Process -Id $PID).Path
    $argumentLine = Get-ElevationArguments -ScriptPath $PSCommandPath -Mode $Mode -Path (ConvertTo-CleanPath -Path $Context.Path) `
        -ShareName $Context.ShareName.Trim() -UserName $Context.UserName.Trim() -ReadOnly:$Context.ReadOnly -Yes:$Context.Yes
    try {
        $process = Start-Process -FilePath $exe -ArgumentList $argumentLine -Verb RunAs -Wait -PassThru -ErrorAction Stop
    } catch {
        Write-Bad 'Administrator permission was not given, so nothing was changed.'
        return 1
    }
    Write-Info 'The administrator window has finished.'
    return [int]$process.ExitCode
}

function Resolve-Target([string]$HostName) {
    try {
        return @([System.Net.Dns]::GetHostAddresses($HostName) | ForEach-Object { $_.IPAddressToString })
    } catch {
        Write-Verbose "Name lookup for $HostName failed: $($_.Exception.Message)"
        return @()
    }
}

function Test-Port445([string]$HostName, [int]$TimeoutMs = 3000) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $pending = $client.BeginConnect($HostName, 445, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($pending)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Invoke-DirectoryProbe([string]$Unc) {
    $enumerator = [System.IO.Directory]::EnumerateFileSystemEntries($Unc).GetEnumerator()
    try { [void]$enumerator.MoveNext() } finally { $enumerator.Dispose() }
}

function Test-ShareAccess([string]$Unc) {
    # Returns { Code, Message }. Code 0 means the share opens.
    try {
        Invoke-DirectoryProbe -Unc $Unc
        return [pscustomobject]@{ Code = 0; Message = '' }
    } catch {
        return (Get-AccessErrorCode -Exception $_.Exception)
    }
}

function Get-UsedDriveLetter {
    $fromDrives = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1) })
    $fromMappings = @(Get-SmbMapping -ErrorAction SilentlyContinue | Where-Object { $_.LocalPath } | ForEach-Object { $_.LocalPath.Substring(0, 1) })
    $fromRegistry = @(Get-ChildItem -Path 'HKCU:\Network' -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName })
    return @(@($fromDrives) + @($fromMappings) + @($fromRegistry) | ForEach-Object { "$_".ToUpperInvariant() } | Select-Object -Unique)
}

function Get-FreeDriveLetter {
    return (Select-FreeDriveLetter -Used (Get-UsedDriveLetter))
}

function Get-LocalIPv4Address {
    return @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' } | ForEach-Object { $_.IPAddress })
}

function Get-FirewallGroupState([string]$Group) {
    $rules = @(Get-NetFirewallRule -Group $Group -ErrorAction SilentlyContinue |
        Where-Object { "$($_.Direction)" -eq 'Inbound' -and "$($_.Profile)" -match 'Private|Any' })
    $enabled = @($rules | Where-Object { "$($_.Enabled)" -eq 'True' })
    $display = if ($rules.Count) { $rules[0].DisplayGroup } else { $Group }
    return [pscustomobject]@{ Name = $display; Total = $rules.Count; Enabled = $enabled.Count }
}

function Test-HiddenFromSignIn([string]$Name) {
    try {
        $item = Get-ItemProperty -Path $SignInListKey -Name $Name -ErrorAction Stop
        return ($item.$Name -eq 0)
    } catch {
        return $false
    }
}

function Get-EveryoneAccountName {
    # "Everyone" in the display language of this PC.
    try {
        return ([System.Security.Principal.SecurityIdentifier]::new($EveryoneSid)).Translate([System.Security.Principal.NTAccount]).Value
    } catch {
        return 'Everyone'
    }
}

function Get-FailureExitCode([System.Exception]$Exception) {
    $e = $Exception
    while ($e) {
        if ($e -is [System.OperationCanceledException]) { return 2 }
        $e = $e.InnerException
    }
    return 1
}

#endregion

#region ---------- Host: share a folder ----------

function Get-HostFolder {
    param([Parameter(Mandatory)] $Context)
    Write-Step 'Folder to share'
    $typed = $Context.Path
    if (-not $typed.Trim()) {
        $typed = Read-Answer -Context $Context -Prompt 'Full path of the folder to share (for example D:\Media)' -Missing 'the folder to share (-Path)'
    }
    $check = Test-SharePath -Path $typed
    if (-not $check.Ok) { throw $check.Reason }
    if ($check.IsDriveRoot) {
        Write-Warn "This shares the whole $($check.FullPath.Substring(0, 2)) drive. Setting permissions on a large drive can take a few minutes."
        if (-not (Confirm-Step -Context $Context -Question 'Continue?')) { throw (Get-CancelError) }
    }
    Write-Ok "Folder: $($check.FullPath)"
    return $check
}

function Get-HostShareName {
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)] $Folder)
    $name = $Context.ShareName.Trim()
    if (-not $name) {
        $default = Get-DefaultShareName -FullPath $Folder.FullPath -IsRoot $Folder.IsDriveRoot
        $name = Read-Answer -Context $Context -Prompt 'Share name other PCs will see' -Default $default -Missing 'a share name (-ShareName)'
    }
    if (-not (Test-ShareNameValid -Name $name)) {
        throw "'$name' is not a valid share name. Avoid \ / : * ? `" < > | and keep it to 80 characters or fewer."
    }
    $existing = Get-SmbShare -Name $name -ErrorAction SilentlyContinue
    if ($existing -and ($existing.Path.TrimEnd('\') -ne $Folder.FullPath.TrimEnd('\'))) {
        throw "A share named '$name' already exists for $($existing.Path). Run again with a different -ShareName."
    }
    Write-Ok "Share name: $name"
    return $name
}

function Read-NewPassword {
    # Uses -Password when given, otherwise asks twice. Returns a SecureString.
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)] [string]$ForUser)
    if ($null -ne $Context.Password) {
        $problem = Get-PasswordProblem -Password $Context.Password
        if ($problem) { throw $problem }
        return $Context.Password
    }
    if (Test-NoPrompt -Context $Context) { throw (Get-MissingInputError -Missing "a password for '$ForUser' (-Password)") }
    while ($true) {
        $first = Read-Host "  Choose a password for '$ForUser'" -AsSecureString
        $problem = Get-PasswordProblem -Password $first
        if ($problem) { Write-Warn $problem; continue }
        $second = Read-Host '  Type it again' -AsSecureString
        if (-not (Test-SecureStringMatch -First $first -Second $second)) { Write-Warn 'The two passwords did not match. Try again.'; continue }
        return $first
    }
}

function Get-HostAccount {
    # Validates the share account and collects its password. Changes nothing yet.
    param([Parameter(Mandatory)] $Context)
    Write-Step 'Share account'
    $name = $Context.UserName.Trim()
    if (-not (Test-UserNameValid -Name $name)) {
        throw "'$name' is not a valid Windows username. Use 1-20 characters, none of \ / [ ] : ; | = , + * ? < > @ `", and do not end it with a dot."
    }
    if ($name -eq $env:USERNAME) {
        throw "'$name' is your own account. ShareDoctor never changes your own account, so pick a different name for the share account (for example shareuser)."
    }
    $existing = Get-LocalUser -Name $name -ErrorAction SilentlyContinue
    if ($existing -and ($existing.Description -ne $AccountTag)) {
        throw "An account named '$name' already exists on this PC and ShareDoctor did not create it. ShareDoctor never changes other accounts, so pick a different name with -UserName."
    }
    $newPassword = $null
    if ($existing) {
        Write-Ok "Share account '$name' already exists - reusing it."
        if ($null -ne $Context.Password) {
            $newPassword = Read-NewPassword -Context $Context -ForUser $name
        } elseif ($Context.Yes) {
            Write-Info 'Keeping its current password.'
        } elseif (Confirm-Step -Context $Context -Question "Set a new password for '$name'?" -DefaultYes $false) {
            $newPassword = Read-NewPassword -Context $Context -ForUser $name
        }
    } else {
        Write-Info "ShareDoctor will create a standard (non-admin) account '$name' that other PCs use to sign in."
        $newPassword = Read-NewPassword -Context $Context -ForUser $name
    }
    return [pscustomobject]@{
        Name        = $name
        Qualified   = "$env:COMPUTERNAME\$name"
        Existing    = $existing
        NewPassword = $newPassword
    }
}

function Initialize-ShareAccount {
    param([Parameter(Mandatory)] $Account)
    $name = $Account.Name
    if ($Account.Existing) {
        if (-not $Account.Existing.Enabled) {
            Enable-LocalUser -Name $name
            Write-Ok "Re-enabled '$name'."
        }
        if ($null -ne $Account.NewPassword) {
            Set-LocalUser -Name $name -Password $Account.NewPassword -PasswordNeverExpires $true
            Write-Ok 'Password updated. Other PCs that saved the old one need to run Connect again.'
        }
    } else {
        try {
            New-LocalUser -Name $name -Password $Account.NewPassword -PasswordNeverExpires -AccountNeverExpires `
                -UserMayNotChangePassword -Description $AccountTag -ErrorAction Stop | Out-Null
        } catch {
            throw "Windows did not create the account '$name': $($_.Exception.Message)"
        }
        Write-Ok "Created the standard account '$name'."
    }
    try {
        Add-LocalGroupMember -SID $UsersGroupSid -Member $name -ErrorAction Stop
    } catch {
        if ($_.FullyQualifiedErrorId -notmatch 'MemberExists') {
            Write-Warn "Could not add '$name' to the Users group: $($_.Exception.Message)"
        }
    }
}

function Hide-FromSignInScreen([string]$Name) {
    # The share account is only used by other PCs over the network. Keeping it off the
    # sign-in screen means a PC whose own account has no password still starts straight
    # to the desktop, exactly as before.
    try {
        if (-not (Test-Path -Path $SignInListKey)) { New-Item -Path $SignInListKey -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -Path $SignInListKey -Name $Name -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        Write-Ok "'$Name' is hidden from the sign-in screen, so this PC still starts straight into your account."
        return $true
    } catch {
        Write-Bad "Could not hide '$Name' from the sign-in screen: $($_.Exception.Message)"
        Write-Info 'Windows may now show an account picker at startup. Run Host again, or Remove to delete the account.'
        return $false
    }
}

function Set-NetworkPrivate {
    param([Parameter(Mandatory)] $Context)
    $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
    if ($profiles.Count -eq 0) { Write-Warn 'No active network connection found.'; return }
    foreach ($netProfile in $profiles) {
        $label = "'$($netProfile.Name)' ($($netProfile.InterfaceAlias))"
        switch ("$($netProfile.NetworkCategory)") {
            'Public' {
                $question = "Network $label is set to Public, which hides this PC and blocks sharing. Set it to Private? Only do this on a network you trust (home/office)."
                if (Confirm-Step -Context $Context -Question $question) {
                    try {
                        Set-NetConnectionProfile -InterfaceIndex $netProfile.InterfaceIndex -NetworkCategory Private -ErrorAction Stop
                        Write-Ok "Network $label is now Private."
                    } catch {
                        Write-Bad "Could not change $label`: $($_.Exception.Message)"
                    }
                } else {
                    Write-Warn "Left $label as Public - other PCs will not reach this share over it."
                }
            }
            'DomainAuthenticated' { Write-Ok "Network $label is a company domain network, managed by your IT. Left as it is." }
            default { Write-Ok "Network $label is Private." }
        }
    }
}

function Test-PrivateOnlyRule($Rule) {
    # True for rules that cover Private networks but never Public ones. "Any" includes Public.
    $profiles = "$($Rule.Profile)"
    return ($profiles -match 'Private' -and $profiles -notmatch 'Public|Any')
}

function Enable-SharingFirewall {
    foreach ($group in @($FwGroupFileSharing, $FwGroupDiscovery)) {
        $all = @(Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue)
        if ($all.Count -eq 0) { Write-Warn "Firewall rule group $group was not found on this PC."; continue }
        # Only rules for Private networks. Rules that also cover Public networks stay as they are,
        # so sharing never opens up on a cafe or hotel Wi-Fi.
        $rules = @($all | Where-Object { Test-PrivateOnlyRule -Rule $_ })
        if ($rules.Count -eq 0) {
            Write-Warn "'$($all[0].DisplayGroup)' has no firewall rules for Private networks only, so ShareDoctor left it alone."
            Write-Info 'Allow it for Private networks in Windows Security > Firewall & network protection.'
            continue
        }
        try {
            Enable-NetFirewallRule -Name @($rules | ForEach-Object { $_.Name }) -ErrorAction Stop
            Write-Ok "Firewall: '$($rules[0].DisplayGroup)' is allowed on Private networks."
        } catch {
            Write-Warn "Could not change the firewall for '$($rules[0].DisplayGroup)': $($_.Exception.Message)"
        }
    }
}

function Set-SharingService {
    $services = @(
        @{ Name = 'LanmanServer'; Why = 'shares folders from this PC' },
        @{ Name = 'FDResPub'; Why = 'makes this PC visible under Network' },
        @{ Name = 'fdPHost'; Why = 'finds other PCs on the network' }
    )
    foreach ($service in $services) {
        $svc = Get-Service -Name $service.Name -ErrorAction SilentlyContinue
        if (-not $svc) { Write-Warn "Service $($service.Name) was not found."; continue }
        try {
            if ("$($svc.StartType)" -ne 'Automatic') { Set-Service -Name $service.Name -StartupType Automatic -ErrorAction Stop }
            if ("$($svc.Status)" -ne 'Running') { Start-Service -Name $service.Name -ErrorAction Stop }
            Write-Ok "Service '$($svc.DisplayName)' is running ($($service.Why))."
        } catch {
            Write-Warn "Could not start '$($svc.DisplayName)': $($_.Exception.Message)"
        }
    }
}

function Publish-Share {
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)] $Folder, [Parameter(Mandatory)] [string]$Name, [Parameter(Mandatory)] $Account)
    Write-Step 'Sharing the folder'
    $right = if ($Context.ReadOnly) { 'Read' } else { 'Change' }
    $existing = Get-SmbShare -Name $Name -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.Path.TrimEnd('\') -ne $Folder.FullPath.TrimEnd('\')) {
            throw "A share named '$Name' already exists for $($existing.Path). Run again with a different -ShareName."
        }
        Grant-SmbShareAccess -Name $Name -AccountName $Account.Qualified -AccessRight $right -Force -ErrorAction Stop | Out-Null
        Write-Ok "Share '$Name' already existed - gave '$($Account.Name)' $right access."
        return
    }
    # Only the share account gets access. Never Everyone.
    if ($Context.ReadOnly) {
        New-SmbShare -Name $Name -Path $Folder.FullPath -Description 'Shared with ShareDoctor' -ReadAccess $Account.Qualified -ErrorAction Stop | Out-Null
    } else {
        New-SmbShare -Name $Name -Path $Folder.FullPath -Description 'Shared with ShareDoctor' -ChangeAccess $Account.Qualified -ErrorAction Stop | Out-Null
    }
    Write-Ok "Shared '$($Folder.FullPath)' as '$Name' ($right access for '$($Account.Name)')."
}

function Grant-FolderAccess {
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)] $Folder, [Parameter(Mandatory)] $Account)
    $permission = if ($Context.ReadOnly) { 'RX' } else { 'M' }
    $result = Invoke-Native -FilePath 'icacls.exe' -Arguments @($Folder.FullPath, '/grant', "$($Account.Qualified):(OI)(CI)$permission")
    if ($result.ExitCode -eq 0) {
        $can = if ($Context.ReadOnly) { 'read' } else { 'read and change' }
        Write-Ok "Folder permissions: '$($Account.Name)' can $can files."
    } else {
        Write-Warn 'Could not set folder permissions (drives formatted FAT32/exFAT have none - that is fine).'
        if ($result.Output) { Write-Info $result.Output }
    }
}

function Show-HostSummary {
    param([Parameter(Mandatory)] [string]$Name, [Parameter(Mandatory)] $Account)
    $addresses = @(Get-LocalIPv4Address | Where-Object { $_ -notlike '169.254.*' })
    $passwordNote = if ($null -ne $Account.NewPassword) { 'the one you just chose' } else { 'the one you chose for this account before' }
    Write-Step 'Done - how to open it from the other PC'
    Write-Info "In File Explorer's address bar, type:   \\$env:COMPUTERNAME\$Name"
    foreach ($address in $addresses) { Write-Info "or use the IP address:                  \\$address\$Name" }
    Write-Info ''
    Write-Info "Sign in with   username: $($Account.Qualified)"
    Write-Info "               password: $passwordNote   (tick `"Remember my credentials`")"
    Write-Info ''
    Write-Info 'Easiest: run ShareDoctor on the other PC and choose 2 (Connect).'
}

function Invoke-HostMode {
    param([Parameter(Mandatory)] $Context)
    if (-not (Test-IsAdmin)) {
        Write-Info 'Sharing a folder needs administrator rights. Asking Windows for permission...'
        return (Invoke-Elevated -Context $Context -Mode 'Host')
    }

    # Collect and check everything first, so a typo never leaves a half-done setup.
    $folder = Get-HostFolder -Context $Context
    $shareName = Get-HostShareName -Context $Context -Folder $folder
    $account = Get-HostAccount -Context $Context

    Initialize-ShareAccount -Account $account
    $hidden = Hide-FromSignInScreen -Name $account.Name

    Write-Step 'Network, firewall and services'
    Set-NetworkPrivate -Context $Context
    Enable-SharingFirewall
    Set-SharingService

    Publish-Share -Context $Context -Folder $folder -Name $shareName -Account $account
    Grant-FolderAccess -Context $Context -Folder $folder -Account $account
    Show-HostSummary -Name $shareName -Account $account
    if (-not $hidden) { return 1 }
    return 0
}

#endregion

#region ---------- Connect: open a shared folder ----------

function Disconnect-OldConnection {
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)] [string]$Target)
    $old = @(Get-SmbMapping -ErrorAction SilentlyContinue | Where-Object { $_.RemotePath -like "\\$Target\*" })
    if ($old.Count -eq 0) { return }
    Write-Warn "This PC already has connections to $Target`:"
    foreach ($mapping in $old) { Write-Info ("$($mapping.LocalPath) $($mapping.RemotePath)".Trim()) }
    if (-not (Confirm-Step -Context $Context -Question 'Disconnect them first? This is needed if they used a different username.')) { return }
    foreach ($mapping in $old) {
        $what = if ($mapping.LocalPath) { $mapping.LocalPath } else { $mapping.RemotePath }
        [void](Invoke-Native -FilePath 'net.exe' -Arguments @('use', $what, '/delete', '/y'))
    }
    Write-Ok 'Old connections removed.'
}

function Save-ShareCredential {
    # Saves the sign-in in Windows Credential Manager. Returns $true when it worked.
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)] [string]$Target, [Parameter(Mandatory)] [string]$User)
    $secure = $Context.Password
    if ($null -eq $secure) {
        $secure = Read-Secret -Context $Context -Prompt "Password for $User" -Missing "the share account's password (-Password)"
    }
    $plain = ConvertTo-Plain -Secure $secure
    if ([string]::IsNullOrEmpty($plain)) {
        $plain = $null
        Write-Bad (Get-ErrorAdvice -Code 1327)
        return $false
    }
    $saved = Invoke-Native -FilePath 'cmdkey.exe' -Arguments @("/add:$Target", "/user:$User", "/pass:$plain")
    $plain = $null
    if ($saved.ExitCode -ne 0) {
        Write-Bad "Could not save the sign-in: $($saved.Output)"
        return $false
    }
    Write-Ok "Sign-in saved in Windows Credential Manager for '$Target'. Keep using that same name (or IP) and Windows will not ask again."
    return $true
}

function Mount-ShareDrive {
    # Maps the drive letter if wanted. Returns the path to open in File Explorer.
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)] [string]$Unc, [string]$Letter = '')
    $chosen = $Letter
    if (-not $chosen -and -not $Context.NoDriveLetter) {
        $free = Get-FreeDriveLetter
        if ($free -and (Confirm-Step -Context $Context -Question "Show it as drive ${free}: in This PC?")) { $chosen = "${free}:" }
    }
    if (-not $chosen) { return $Unc }
    Write-Step 'Drive letter'
    $map = Invoke-Native -FilePath 'net.exe' -Arguments @('use', $chosen, $Unc, '/persistent:yes')
    if ($map.ExitCode -ne 0) {
        Write-Warn "Could not map drive $chosen`: $($map.Output)"
        return $Unc
    }
    Write-Ok "Drive $chosen is $Unc and will come back after restarts."
    return "$chosen\"
}

function Invoke-ConnectMode {
    param([Parameter(Mandatory)] $Context)
    if (Test-IsAdmin) {
        Write-Warn 'This window is running as administrator. Drives mapped here usually do not show up in File Explorer.'
        Write-Info 'Close it and run ShareDoctor normally (double-click ShareDoctor.cmd) to connect.'
        if (-not (Confirm-Step -Context $Context -Question 'Continue anyway?' -DefaultYes $false)) { throw (Get-CancelError) }
    }
    $letter = ''
    if ($Context.DriveLetter.Trim()) { $letter = ConvertTo-DriveLetter -Letter $Context.DriveLetter }

    Write-Step 'Which shared folder?'
    $target = $Context.Computer.Trim().Trim('\')
    if (-not $target) {
        $target = (Read-Answer -Context $Context -Prompt 'Name or IP address of the PC that has the files' -Missing 'the name or IP address of the PC that has the files (-Computer)').Trim('\')
    }
    $share = $Context.ShareName.Trim().Trim('\')
    if (-not $share) {
        $share = (Read-Answer -Context $Context -Prompt 'Share name' -Missing 'the share name (-ShareName)').Trim('\')
    }
    if (-not $target -or -not $share) { throw 'Both the PC name and the share name are needed.' }
    $unc = "\\$target\$share"

    Write-Step "Reaching $target"
    $addresses = @(Resolve-Target -HostName $target)
    if ($addresses.Count -eq 0) {
        Write-Bad "This PC cannot find '$target' on the network."
        Write-Info 'Use its IP address instead (Host mode prints it), and check that both PCs are on the same network.'
        return 1
    }
    Write-Ok "Found $target at $($addresses -join ', ')"
    if (-not (Test-Port445 -HostName $target)) {
        Write-Bad "$target does not answer on the file sharing port (445)."
        Write-Info (Get-ErrorAdvice -Code 53)
        return 1
    }
    Write-Ok "$target is accepting file sharing connections."
    Disconnect-OldConnection -Context $Context -Target $target

    Write-Step 'Sign in'
    $defaultUser = Format-ConnectUserName -Typed $Context.UserName -Target $target
    $typedUser = Read-Answer -Context $Context -Prompt "Username on $target" -Default $defaultUser -Missing 'a username (-UserName)'
    $user = Format-ConnectUserName -Typed $typedUser -Target $target
    if (-not (Save-ShareCredential -Context $Context -Target $target -User $user)) { return 1 }

    Write-Step 'Testing access'
    $result = Test-ShareAccess -Unc $unc
    if ($result.Code -ne 0) {
        Write-Bad (Get-ErrorAdvice -Code $result.Code -Message $result.Message)
        if (($SignInErrorCodes -contains $result.Code) -and (Confirm-Step -Context $Context -Question 'Remove the saved sign-in so you can try again?')) {
            [void](Invoke-Native -FilePath 'cmdkey.exe' -Arguments @("/delete:$target"))
            Write-Ok 'Removed the saved sign-in.'
        }
        return 1
    }
    Write-Ok "You can open $unc"

    $openPath = Mount-ShareDrive -Context $Context -Unc $unc -Letter $letter
    if (-not $Context.NoOpen) { Start-Process -FilePath 'explorer.exe' -ArgumentList $openPath }
    return 0
}

#endregion

#region ---------- Diagnose: read-only checks ----------

function Invoke-SafeCheck([string]$Area, [scriptblock]$Check, [object[]]$ArgumentList = @()) {
    # A broken check must never stop the others.
    try {
        & $Check @ArgumentList
    } catch {
        Get-CheckResult -Area $Area -Check 'Check could not run' -Status 'Info' -Detail "ShareDoctor could not check this: $($_.Exception.Message)"
    }
}

function Get-OsInfo {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        return [pscustomobject]@{ Caption = "$($os.Caption)".Trim(); Build = "$($os.BuildNumber)" }
    } catch {
        return [pscustomobject]@{ Caption = 'Windows'; Build = '' }
    }
}

function Get-ThisPcCheck($Os) {
    $area = 'This PC'
    Get-CheckResult -Area $area -Check 'Windows version' -Status 'Info' -Detail "$($Os.Caption) (build $($Os.Build)), PC name: $env:COMPUTERNAME"
    $addresses = @(Get-LocalIPv4Address)
    if ($addresses.Count -eq 0) {
        Get-CheckResult -Area $area -Check 'IP addresses' -Status 'Warn' -Detail 'This PC has no network address.' -Fix 'Connect this PC to your network (cable or Wi-Fi).'
        return
    }
    Get-CheckResult -Area $area -Check 'IP addresses' -Status 'Info' -Detail "IP address(es): $($addresses -join ', ')"
    if (@($addresses | Where-Object { $_ -like '169.254.*' }).Count -gt 0) {
        Get-CheckResult -Area $area -Check 'Self-assigned address' -Status 'Warn' `
            -Detail 'A 169.254.x.x address means a network adapter did not get an address from the router.' `
            -Fix 'Check the cable or Wi-Fi connection, then restart the router and this PC.'
    }
}

function Get-NetworkTypeCheck {
    $area = 'Network type'
    $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
    if ($profiles.Count -eq 0) {
        Get-CheckResult -Area $area -Check 'Active network' -Status 'Warn' -Detail 'No active network connection found.' -Fix 'Connect this PC to your network (cable or Wi-Fi).'
        return
    }
    foreach ($netProfile in $profiles) {
        $label = "'$($netProfile.Name)' ($($netProfile.InterfaceAlias))"
        $category = "$($netProfile.NetworkCategory)"
        switch ($category) {
            'Public' {
                Get-CheckResult -Area $area -Check "Network $label" -Status 'Fail' `
                    -Detail "Network $label is Public - Windows hides this PC and blocks sharing on it." `
                    -Fix "Set network $label to Private: Settings > Network & internet > your network > Private, or run Host mode."
            }
            'DomainAuthenticated' {
                Get-CheckResult -Area $area -Check "Network $label" -Status 'Info' -Detail "Network $label is a company domain network, managed by your IT."
            }
            default {
                Get-CheckResult -Area $area -Check "Network $label" -Status 'Ok' -Detail "Network $label is $category."
            }
        }
    }
}

function Get-FirewallCheck {
    $area = 'Firewall'
    foreach ($group in @($FwGroupFileSharing, $FwGroupDiscovery)) {
        $state = Get-FirewallGroupState -Group $group
        $fix = "Allow '$($state.Name)' in Windows Firewall for Private networks (Host mode does this)."
        if ($state.Total -eq 0) {
            Get-CheckResult -Area $area -Check $group -Status 'Warn' -Detail "Firewall rule group $group was not found."
        } elseif ($state.Enabled -eq 0) {
            Get-CheckResult -Area $area -Check $state.Name -Status 'Fail' -Detail "'$($state.Name)' is blocked on Private networks." -Fix $fix
        } elseif ($state.Enabled -lt $state.Total) {
            Get-CheckResult -Area $area -Check $state.Name -Status 'Warn' -Detail "'$($state.Name)' is only partly allowed ($($state.Enabled) of $($state.Total) rules)." -Fix $fix
        } else {
            Get-CheckResult -Area $area -Check $state.Name -Status 'Ok' -Detail "'$($state.Name)' is allowed on Private networks."
        }
    }
    # Third-party firewalls register here on client Windows. Servers have no such namespace.
    $products = @()
    try { $products = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName FirewallProduct -ErrorAction Stop) } catch { Write-Verbose 'No Security Center on this PC.' }
    foreach ($product in $products) {
        Get-CheckResult -Area $area -Check "Other firewall: $($product.displayName)" -Status 'Warn' `
            -Detail "$($product.displayName) is also acting as a firewall. Its own settings can block sharing even when Windows Firewall allows it." `
            -Fix "Check $($product.displayName): allow local network / file and printer sharing in its settings."
    }
}

function Get-ServiceCheck {
    $area = 'Services'
    $services = @(
        @{ Name = 'LanmanServer'; Why = 'needed to share folders from this PC' },
        @{ Name = 'LanmanWorkstation'; Why = 'needed to open folders on other PCs' },
        @{ Name = 'FDResPub'; Why = 'needed for this PC to appear under Network' }
    )
    foreach ($service in $services) {
        $svc = Get-Service -Name $service.Name -ErrorAction SilentlyContinue
        if (-not $svc) {
            Get-CheckResult -Area $area -Check $service.Name -Status 'Warn' -Detail "Service $($service.Name) was not found."
        } elseif ("$($svc.Status)" -eq 'Running') {
            Get-CheckResult -Area $area -Check $service.Name -Status 'Ok' -Detail "'$($svc.DisplayName)' is running."
        } else {
            Get-CheckResult -Area $area -Check $service.Name -Status 'Fail' -Detail "'$($svc.DisplayName)' is $($svc.Status) ($($service.Why))." `
                -Fix "Start the '$($svc.DisplayName)' service (Host mode does this for sharing)."
        }
    }
}

function Get-AccountTypeCheck {
    $area = 'Your account'
    try {
        $me = Get-LocalUser -Name $env:USERNAME -ErrorAction Stop
    } catch {
        if ($_.FullyQualifiedErrorId -like 'UserNotFound*') {
            Get-CheckResult -Area $area -Check 'Account type' -Status 'Info' -Detail "Account '$env:USERNAME' is a work/school or domain account."
        } else {
            Get-CheckResult -Area $area -Check 'Account type' -Status 'Info' -Detail "Could not read your account type: $($_.Exception.Message)"
        }
        return
    }
    if ("$($me.PrincipalSource)" -eq 'MicrosoftAccount') {
        Get-CheckResult -Area $area -Check 'Account type' -Status 'Warn' `
            -Detail 'You sign in with a Microsoft account. Other PCs must use your email address and its password to reach this PC - a PIN does not work over the network.' `
            -Fix 'Use a ShareDoctor share account instead (run Host mode on this PC), so other PCs never need your Microsoft account details.'
    } else {
        Get-CheckResult -Area $area -Check 'Account type' -Status 'Info' -Detail "Local account '$env:USERNAME'. Accounts with no password can never be used over the network."
    }
}

function Get-ShareListCheck {
    $area = 'Folders this PC shares'
    if (-not (Test-IsAdmin)) {
        Get-CheckResult -Area $area -Check 'Shares' -Status 'Info' -Detail "Run ShareDoctor as administrator to list this PC's shares."
        return
    }
    $shares = @(Get-SmbShare -ErrorAction Stop | Where-Object { -not $_.Name.EndsWith('$') })
    if ($shares.Count -eq 0) {
        Get-CheckResult -Area $area -Check 'Shares' -Status 'Info' -Detail 'None.'
        return
    }
    $everyone = Get-EveryoneAccountName
    foreach ($share in $shares) {
        $access = @(Get-SmbShareAccess -Name $share.Name -ErrorAction SilentlyContinue)
        $who = ($access | ForEach-Object { "$($_.AccountName) ($($_.AccessControlType) $($_.AccessRight))" }) -join ', '
        Get-CheckResult -Area $area -Check "\\$env:COMPUTERNAME\$($share.Name)" -Status 'Info' -Detail "\\$env:COMPUTERNAME\$($share.Name) -> $($share.Path)   allowed: $who"
        $allowed = @($access | Where-Object { "$($_.AccessControlType)" -eq 'Allow' })
        $others = @($allowed | Where-Object { $_.AccountName -ne $everyone })
        if ($allowed.Count -gt 0 -and $others.Count -eq 0) {
            Get-CheckResult -Area $area -Check "Guest-style share $($share.Name)" -Status 'Warn' `
                -Detail "'$($share.Name)' only allows $everyone. Modern Windows PCs will not connect as a guest, so they need a real account here - run Host mode for this folder." `
                -Fix "Run Host mode for the folder shared as '$($share.Name)' so it has a proper share account."
        }
    }
}

function Get-ShareAccountCheck {
    $area = 'ShareDoctor accounts'
    $accounts = @(Get-LocalUser -ErrorAction Stop | Where-Object { $_.Description -eq $AccountTag })
    if ($accounts.Count -eq 0) {
        Get-CheckResult -Area $area -Check 'Share accounts' -Status 'Info' -Detail 'No ShareDoctor share account on this PC.'
        return
    }
    foreach ($account in $accounts) {
        $name = $account.Name
        if (-not $account.Enabled) {
            Get-CheckResult -Area $area -Check "$name enabled" -Status 'Warn' -Detail "The share account '$name' is disabled, so other PCs cannot sign in with it." `
                -Fix "Run Host mode again to re-enable '$name'."
        } else {
            Get-CheckResult -Area $area -Check "$name enabled" -Status 'Ok' -Detail "The share account '$name' is enabled."
        }
        if (Test-HiddenFromSignIn -Name $name) {
            Get-CheckResult -Area $area -Check "$name hidden" -Status 'Ok' -Detail "'$name' is hidden from the sign-in screen."
        } else {
            Get-CheckResult -Area $area -Check "$name hidden" -Status 'Warn' -Detail "'$name' shows on the sign-in screen, so this PC may stop at an account picker when it starts." `
                -Fix "Run Host mode again so '$name' is hidden from the sign-in screen."
        }
    }
}

function Get-ConnectionCheck([string]$Target, [string]$Share) {
    $area = "Connection to $Target"
    $addresses = @(Resolve-Target -HostName $Target)
    if ($addresses.Count -eq 0) {
        Get-CheckResult -Area $area -Check 'Name lookup' -Status 'Fail' -Detail "Cannot find '$Target' by name." -Fix "Use the IP address of '$Target' instead of its name."
        return
    }
    Get-CheckResult -Area $area -Check 'Name lookup' -Status 'Ok' -Detail "Found at $($addresses -join ', ')"
    if (-not (Test-Port445 -HostName $Target)) {
        Get-CheckResult -Area $area -Check 'File sharing port' -Status 'Fail' -Detail 'It does not answer on the file sharing port (445).' -Fix (Get-ErrorAdvice -Code 53)
        return
    }
    Get-CheckResult -Area $area -Check 'File sharing port' -Status 'Ok' -Detail 'It is accepting file sharing connections.'
    if ($Share) {
        $unc = "\\$Target\$Share"
        $result = Test-ShareAccess -Unc $unc
        if ($result.Code -eq 0) {
            Get-CheckResult -Area $area -Check 'Share access' -Status 'Ok' -Detail "$unc opens fine."
        } else {
            Get-CheckResult -Area $area -Check 'Share access' -Status 'Fail' -Detail "$unc fails with Windows error $($result.Code)." -Fix (Get-ErrorAdvice -Code $result.Code -Message $result.Message)
        }
        return
    }
    $view = Invoke-Native -FilePath 'net.exe' -Arguments @('view', "\\$Target")
    if ($view.ExitCode -eq 0) {
        Get-CheckResult -Area $area -Check 'Share list' -Status 'Ok' -Detail 'Its shared folders:'
        foreach ($line in ($view.Output -split "`n")) {
            if ($line.Trim()) { Get-CheckResult -Area $area -Check 'Share list' -Status 'Info' -Detail $line.TrimEnd() }
        }
        return
    }
    $code = Get-NetViewErrorCode -Output $view.Output
    Get-CheckResult -Area $area -Check 'Share list' -Status 'Fail' -Detail "Listing its shares failed: $($view.Output)" -Fix (Get-ErrorAdvice -Code $code -Message $view.Output)
}

function Get-DiagnoseReport {
    # Runs every read-only check. Returns { Version, ComputerName, OsCaption, OsBuild, Results }.
    param([string]$Target = '', [string]$Share = '')
    $os = Get-OsInfo
    $results = @(
        Invoke-SafeCheck -Area 'This PC' -Check { Get-ThisPcCheck -Os $os }
        Invoke-SafeCheck -Area 'Network type' -Check { Get-NetworkTypeCheck }
        Invoke-SafeCheck -Area 'Firewall' -Check { Get-FirewallCheck }
        Invoke-SafeCheck -Area 'Services' -Check { Get-ServiceCheck }
        Invoke-SafeCheck -Area 'Your account' -Check { Get-AccountTypeCheck }
        Invoke-SafeCheck -Area 'Folders this PC shares' -Check { Get-ShareListCheck }
        Invoke-SafeCheck -Area 'ShareDoctor accounts' -Check { Get-ShareAccountCheck }
        if ($Target) {
            Invoke-SafeCheck -Area "Connection to $Target" -ArgumentList $Target, $Share -Check {
                param([string]$To, [string]$Folder)
                Get-ConnectionCheck -Target $To -Share $Folder
            }
        }
    )
    return [pscustomobject]@{
        Version      = $ShareDoctorVersion
        ComputerName = $env:COMPUTERNAME
        OsCaption    = $os.Caption
        OsBuild      = $os.Build
        Results      = $results
    }
}

function Write-DiagnoseReport($Report) {
    $area = ''
    foreach ($result in $Report.Results) {
        if ($result.Area -ne $area) { Write-Step $result.Area; $area = $result.Area }
        switch ($result.Status) {
            'Ok' { Write-Ok $result.Detail }
            'Warn' { Write-Warn $result.Detail }
            'Fail' { Write-Bad $result.Detail }
            default { Write-Info $result.Detail }
        }
    }
    Write-Step 'Summary'
    $fixes = @(Get-DiagnoseFix -Report $Report)
    if ($fixes.Count -eq 0) {
        Write-Ok 'No problems found.'
        return
    }
    for ($i = 0; $i -lt $fixes.Count; $i++) { Write-Wrapped -Prefix "  $($i + 1). " -Text $fixes[$i] -Color 'Yellow' }
}

function Invoke-DiagnoseMode {
    # Read-only: must never change anything. Returns { ExitCode, Output }.
    param([Parameter(Mandatory)] $Context)
    $target = $Context.Computer.Trim().Trim('\')
    $share = $Context.ShareName.Trim().Trim('\')
    if (-not $target -and -not $Context.Yes) {
        $target = (Read-OptionalText -Prompt 'Name or IP of the other PC to test (press Enter to check only this PC)').Trim('\')
        if ($target -and -not $share) { $share = (Read-OptionalText -Prompt 'Share name on it (press Enter to just list its shares)').Trim('\') }
    }
    $report = Get-DiagnoseReport -Target $target -Share $share
    $output = $null
    if ($Context.Json) { $output = ConvertTo-DiagnoseJson -Report $report } else { Write-DiagnoseReport -Report $report }
    return [pscustomobject]@{ ExitCode = (Get-DiagnoseExitCode -Report $report); Output = $output }
}

#endregion

#region ---------- Remove: stop sharing ----------

function Remove-ShareAccount {
    # Deletes the share account, but only one ShareDoctor created and no other share still uses.
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)] [string]$Name)
    $user = Get-LocalUser -Name $Name -ErrorAction SilentlyContinue
    if (-not $user) { return }
    if ($user.Description -ne $AccountTag) {
        Write-Info "'$Name' was not created by ShareDoctor, so it is left alone."
        return
    }
    $qualified = "$env:COMPUTERNAME\$Name"
    $stillUsed = @(Get-SmbShare -ErrorAction SilentlyContinue | Where-Object { -not $_.Name.EndsWith('$') } | Where-Object {
            @(Get-SmbShareAccess -Name $_.Name -ErrorAction SilentlyContinue | Where-Object { $_.AccountName -eq $qualified }).Count -gt 0
        } | ForEach-Object { $_.Name })
    if ($stillUsed.Count -gt 0) {
        Write-Info "Kept the share account '$Name' because these shares still use it: $($stillUsed -join ', ')."
        return
    }
    if (-not (Confirm-Step -Context $Context -Question "Also delete the share account '$Name'? Other PCs will no longer be able to sign in with it." -DefaultYes $false)) {
        Write-Info "Kept the share account '$Name'."
        return
    }
    Remove-LocalUser -Name $Name -ErrorAction Stop
    Remove-ItemProperty -Path $SignInListKey -Name $Name -ErrorAction SilentlyContinue
    Write-Ok "Deleted the share account '$Name'."
}

function Invoke-RemoveMode {
    param([Parameter(Mandatory)] $Context)
    if (-not (Test-IsAdmin)) {
        Write-Info 'Stopping a share needs administrator rights. Asking Windows for permission...'
        return (Invoke-Elevated -Context $Context -Mode 'Remove')
    }
    $name = $Context.ShareName.Trim()
    if (-not $name) {
        if (-not (Test-NoPrompt -Context $Context)) {
            Write-Step 'Folders this PC shares'
            foreach ($share in @(Get-SmbShare -ErrorAction SilentlyContinue | Where-Object { -not $_.Name.EndsWith('$') })) { Write-Info "$($share.Name)  ->  $($share.Path)" }
        }
        $name = Read-Answer -Context $Context -Prompt 'Share name to stop sharing' -Missing 'the share name to stop sharing (-ShareName)'
    }
    $account = $Context.UserName.Trim()
    $exitCode = 0

    Write-Step "Stop sharing '$name'"
    $existing = Get-SmbShare -Name $name -ErrorAction SilentlyContinue
    if ($existing) {
        if (-not (Confirm-Step -Context $Context -Question "Stop sharing '$name' ($($existing.Path))? Your files are not touched.")) { throw (Get-CancelError) }
        Remove-SmbShare -Name $name -Force -ErrorAction Stop
        $acl = Invoke-Native -FilePath 'icacls.exe' -Arguments @($existing.Path, '/remove:g', "$env:COMPUTERNAME\$account")
        Write-Ok "'$name' is no longer shared. Your files are still there."
        if ($acl.ExitCode -ne 0) { Write-Info "The folder permission for '$account' was not removed (it may never have been set)." }
    } else {
        Write-Warn "This PC has no share named '$name'."
        $exitCode = 1
    }
    Remove-ShareAccount -Context $Context -Name $account
    return $exitCode
}

#endregion

#region ---------- menu and entry point ----------

function Show-Menu {
    param([Parameter(Mandatory)] $Context)
    if (Test-NoPrompt -Context $Context) {
        throw (Get-CancelError -Message 'With -Yes, choose what to do with -Mode (Host, Connect, Diagnose or Remove).')
    }
    while ($true) {
        Write-Host ''
        Write-Host "ShareDoctor $ShareDoctorVersion - Windows file sharing helper" -ForegroundColor Cyan
        Write-Host '  1  Share a folder from this PC        (on the PC that has the files)'
        Write-Host '  2  Connect to a shared folder         (on the PC that wants the files)'
        Write-Host '  3  Diagnose a sharing problem         (read-only, changes nothing)'
        Write-Host '  4  Stop sharing a folder'
        Write-Host '  Q  Quit'
        $choice = (Read-OptionalText -Prompt 'Choose').ToUpperInvariant()
        switch ($choice) {
            '1' { return (Invoke-HostMode -Context $Context) }
            '2' { return (Invoke-ConnectMode -Context $Context) }
            '3' { return (Invoke-DiagnoseMode -Context $Context).ExitCode }
            '4' { return (Invoke-RemoveMode -Context $Context) }
            'Q' { return 0 }
            default { Write-Warn 'Please type 1, 2, 3, 4 or Q.' }
        }
    }
}

function Invoke-Main {
    # Runs the chosen mode. Returns { ExitCode, Output }; Output holds Diagnose JSON, if any.
    param([Parameter(Mandatory)] $Context)
    $ErrorActionPreference = 'Stop'
    $exitCode = 0
    $output = $null
    try {
        if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) { throw 'ShareDoctor runs on Windows only.' }
        switch ($Context.Mode) {
            'Host' { $exitCode = Invoke-HostMode -Context $Context }
            'Connect' { $exitCode = Invoke-ConnectMode -Context $Context }
            'Diagnose' {
                $diagnosis = Invoke-DiagnoseMode -Context $Context
                $exitCode = $diagnosis.ExitCode
                $output = $diagnosis.Output
            }
            'Remove' { $exitCode = Invoke-RemoveMode -Context $Context }
            default { $exitCode = Show-Menu -Context $Context }
        }
    } catch {
        $exitCode = Get-FailureExitCode -Exception $_.Exception
        if ($exitCode -eq 2) { Write-Warn $_.Exception.Message } else { Write-Bad $_.Exception.Message }
    } finally {
        if ($Context.Relaunched) {
            Write-Host ''
            [void](Read-Host 'Press Enter to close this window')
        }
    }
    return [pscustomobject]@{ ExitCode = [int]$exitCode; Output = $output }
}

#endregion

# Dot-sourcing (". .\ShareDoctor.ps1") only loads the functions. The tests rely on this.
if ($MyInvocation.InvocationName -ne '.') {
    $runContext = New-RunContext -Mode $Mode -Path $Path -ShareName $ShareName -UserName $UserName -Password $Password `
        -Computer $Computer -DriveLetter $DriveLetter -NoDriveLetter:$NoDriveLetter -NoOpen:$NoOpen -ReadOnly:$ReadOnly `
        -Yes:$Yes -Json:$Json -Relaunched:$Relaunched
    $runResult = Invoke-Main -Context $runContext
    if ($null -ne $runResult.Output) { Write-Output $runResult.Output }
    exit $runResult.ExitCode
}
