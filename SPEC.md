# ShareDoctor - Product and Technical Specification

- Spec version: 1.1 (1.1 shortens the account marker to fit the Windows 48-character limit, and records the account-takeover guard, the Diagnose JSON shape and the elevated-window prompt rule)
- Target release: ShareDoctor v0.2.0
- Status: v0.1.0 exists as a working prototype (one PowerShell script plus a .cmd launcher). This document is the source of truth for the rebuild. Where the prototype and this spec differ, the spec wins.
- License: MIT. Free and open source, with no monetisation.

---

## 1. Summary

ShareDoctor is a small Windows tool that makes file sharing between Windows 10/11 PCs on the same local network work, and explains in plain words why it fails. It works *with* modern Windows security instead of switching it off.

GitHub repo description (use as-is):
> Fix "Access denied" on Windows 10/11 network file sharing - without disabling security.

Suggested topics: `windows`, `windows-11`, `windows-10`, `smb`, `file-sharing`, `network-sharing`, `powershell`, `access-denied`, `troubleshooting`.

---

## 2. The problem

### User story
A home or small office has several Windows PCs on one network. The owner signs in with a **local account that has no password and no PIN**, so the PC boots straight to the desktop. They share a folder or a whole drive and turn off "password protected sharing", which worked on Windows 7/8. The other PC then shows **"Access denied"** or **"Windows cannot access \\\\PC\\Share"**, with no explanation.

### Root causes
ShareDoctor must detect and explain each of these:

| # | Cause | Typical symptom |
|---|---|---|
| 1 | Newer Windows versions refuse password-less **guest** connections, and Windows 11 24H2 tightened this further. Turning off "password protected sharing" only offers guest access on the host, and the connecting PC refuses it. | Error 1272, or just "Access denied" |
| 2 | Accounts with a **blank password** are never accepted over the network. | Error 1327 |
| 3 | A **Microsoft account** signs in over the network with its email and account password, never the PIN. | Error 1326 |
| 4 | Network set to **Public**: discovery is off and the sharing firewall rules are inactive. | Error 53, PC not listed under Network |
| 5 | The **File and Printer Sharing** or **Network Discovery** firewall rule groups are disabled for Private networks. | Error 53 / 1231 |
| 6 | A **third-party firewall** (antivirus suite) blocks SMB. | Error 53 / 64 |
| 7 | A service is stopped: Server (`LanmanServer`), Workstation (`LanmanWorkstation`) or Function Discovery Resource Publication (`FDResPub`). | Can't share, can't connect, or not visible |
| 8 | The PC is already connected to the same server under another username. | Error 1219 |
| 9 | Wrong share name, PC off or unreachable, or guest Wi-Fi / AP isolation keeping devices apart. | Error 67 / 53 / 51 / 1231 |

---

## 3. Goals

- **G1** One guided flow to share a folder on the PC with the files ("host"), and one to connect from another PC ("client").
- **G2** **Never add a sign-in screen and never touch the user's own account.** A PC whose own account has no password must still boot straight to the desktop after ShareDoctor runs. This is the reason the project exists.
- **G3** Explain every failure in plain language, with the fix.
- **G4** Work on Windows 10 (1809+) and Windows 11 (including 24H2 and later), in the Home, Pro, Enterprise and Education editions, **in any display language**.
- **G5** Zero install: unzip and double-click. Nothing is needed beyond what ships with Windows.
- **G6** Everything is reversible: a Remove mode, and saved credentials can be deleted.
- **G7** Testable: automated unit tests with mocks, plus a real integration test on a Windows CI runner.

---

## 4. Hard constraints and non-goals

These are deliberate. Reject any change that breaks them, and say why.

- Never enable guest or insecure guest authentication. Never change SMB signing or encryption settings. Never enable SMB1.
- Never change the password, PIN, type, group membership or sign-in settings of the user's own account(s). Only the share account may be created or changed.
- Never create or accept blank-password accounts for sharing.
- Never share the system drive root (for example `C:\`) or anything under `%windir%`.
- Never give the share account admin rights.
- Never grant share access to `Everyone`. Only the share account gets access.
- No telemetry, and no network traffic except to the LAN target the user names.
- No GUI in v0.x (console UI only). A GUI is on the roadmap.

Reason: these protections keep other people on the network out of the user's files, and "fixes" that disable them break with Windows updates.

---

## 5. Core concept: the share account

- On the host, ShareDoctor creates one **standard (non-admin) local account**, default name `shareuser`, with a password the owner chooses.
- It works like a key that only other PCs use. Nobody signs in with it on the PC itself.
- It is **hidden from the sign-in screen** with this registry value:
  `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList`, DWORD named `<username>`, value `0`.
  Without this, adding a second visible account makes Windows show the account picker at startup, which breaks G2.
- Its description is set to the exact marker string `File sharing account (created by ShareDoctor)`. Remove mode uses this marker to recognise accounts ShareDoctor created, and never deletes accounts without it. Host mode only reuses an existing account if it carries this marker.
  The marker is 45 characters because `New-LocalUser` and `Set-LocalUser` reject descriptions longer than 48. (Spec 1.0 used a 53-character marker, which made account creation fail.) A unit test guards the limit.
- On each client, the account's password is typed **once** and saved in Windows Credential Manager (`cmdkey`). After that, the share opens without prompts.

---

## 6. Platform and coding rules

- **Language:** PowerShell. The primary target is **Windows PowerShell 5.1** (built in). It must also run under PowerShell 7 on Windows. The launcher uses `powershell.exe`.
- **No PowerShell 7-only syntax:** no `??`, no `?:` ternary, no `&&` / `||` pipeline chains, no `ForEach-Object -Parallel`, no `Get-Error`, and no `$IsWindows` unless it is guarded by a `PSEdition` check.
- **ASCII-only source files** (5.1 reads BOM-less files as ANSI). **CRLF** line endings for `.ps1` and `.cmd`, enforced by `.gitattributes`.
- **Language-independent:** never match on localized display text. Use:
  - SIDs for groups: Users = `S-1-5-32-545`
  - Firewall rule group resource IDs: `@FirewallAPI.dll,-28502` (File and Printer Sharing) and `@FirewallAPI.dll,-32752` (Network Discovery)
  - Numeric Windows error codes taken from exception HResults
  - The one allowed fallback: parsing the first number out of `net view` error output.
- **Native commands** (`icacls`, `net`, `cmdkey`) run through one helper, `Invoke-Native`. It temporarily sets `$ErrorActionPreference = 'Continue'`, because 5.1 turns native stderr into terminating errors under `Stop`, and it returns `ExitCode` and `Output`.
- **Single-file distribution:** all code lives in `ShareDoctor.ps1`. The main entry point is guarded, so dot-sourcing loads the functions without running anything (the tests rely on this):
  ```powershell
  if ($MyInvocation.InvocationName -ne '.') { exit (Invoke-Main) }
  ```
- Pure logic goes in small functions with no side effects, so it can be unit-tested. Examples: validation, name defaults, error mapping, building the elevation argument string.
- PSScriptAnalyzer must be clean with the repo settings file (section 13.1).
- Passwords are `SecureString` everywhere, except the moment one is passed to `cmdkey`. Clear the plain-text variable straight after. Never print or log a password.

---

## 7. Repository layout

```
ShareDoctor/
  ShareDoctor.ps1                 # the whole tool (single file)
  ShareDoctor.cmd                 # double-click launcher
  README.md                       # user-facing docs
  SPEC.md                         # this file
  CLAUDE.md                       # instructions for Claude Code
  CHANGELOG.md                    # Keep a Changelog format
  LICENSE                         # MIT, Copyright (c) 2026 Joel Stain Lobo
  PSScriptAnalyzerSettings.psd1
  .gitattributes                  # *.ps1, *.cmd -> eol=crlf ; *.md -> eol=lf
  tests/
    Unit.Tests.ps1                # Pester 5, mocked, no admin, no system changes
    Integration.Tests.ps1         # Pester 5, Tag 'Integration', admin, real changes + cleanup
  docs/
    TESTING.md                    # manual two-PC test matrix and results
  build/
    Build-Release.ps1             # builds dist/ShareDoctor-vX.Y.Z.zip
  .github/
    workflows/ci.yml
    workflows/release.yml
    ISSUE_TEMPLATE/bug_report.md
```

### Launcher (`ShareDoctor.cmd`)
```bat
@echo off
rem ShareDoctor launcher - double-click this file. Runs ShareDoctor.ps1 without changing your system's script policy.
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ShareDoctor.ps1" %*
echo.
pause
```
`-ExecutionPolicy Bypass` applies only to this one process. It is not a system change.

---

## 8. Command-line interface

```
ShareDoctor.ps1 [-Mode Menu|Host|Connect|Diagnose|Remove] [options]
```

| Parameter | Type | Used by | Meaning |
|---|---|---|---|
| `-Mode` | string, default `Menu` | all | Which mode to run. |
| `-Path` | string | Host | Folder to share. |
| `-ShareName` | string | Host, Connect, Diagnose, Remove | Share name. |
| `-UserName` | string, default `shareuser` | Host, Connect, Remove | The share account's name (on Connect, the default username offered). |
| `-Password` | SecureString | Host, Connect | For automation and tests. Prompted for if absent. |
| `-Computer` | string | Connect, Diagnose | Name or IP of the PC that has the files. |
| `-DriveLetter` | string | Connect | Drive letter to map, for example `M`. |
| `-NoDriveLetter` | switch | Connect | Don't map a drive letter. |
| `-NoOpen` | switch | Connect | Don't open File Explorer at the end. |
| `-ReadOnly` | switch | Host | The share account gets read-only access. |
| `-Yes` | switch | all | Answer yes to every confirmation and **never prompt**. Values with a default (share name, Connect username) use the default. If a required value is missing, fail with a clear message and exit code 2. The one exception is the elevated window ShareDoctor opens itself (`-Relaunched`): the user is present and the password is never passed across, so it may still ask for missing values. |
| `-Json` | switch | Diagnose | Print the results as JSON instead of console text. |
| `-Relaunched` | switch | internal | Set when the script re-launches itself elevated. It waits for Enter before the window closes. |

### Exit codes
- `0`: success (Diagnose: no failures)
- `1`: error
- `2`: cancelled, or a required input was missing in `-Yes` mode
- `3`: Diagnose found at least one failure

### Menu (default mode)
```
ShareDoctor 0.2.0 - Windows file sharing helper
  1  Share a folder from this PC        (on the PC that has the files)
  2  Connect to a shared folder         (on the PC that wants the files)
  3  Diagnose a sharing problem         (read-only, changes nothing)
  4  Stop sharing a folder
  Q  Quit
```
An invalid choice re-prompts. Options 1 and 4 need admin (section 9.0).

---

## 9. Modes in detail

### 9.0 Elevation (Host and Remove)
If the current process isn't elevated, ShareDoctor re-launches itself with `Start-Process <current exe> -Verb RunAs`, passing `-NoProfile -ExecutionPolicy Bypass -File "<script>" -Mode <mode> -Relaunched` plus `-Path`, `-ShareName`, `-UserName`, `-ReadOnly` and `-Yes` when they are set.
- Wrap each value in double quotes. **Double a trailing backslash** (`"D:\"` becomes `"D:\\"`), because otherwise it escapes the closing quote.
- **Never pass the password** across. The elevated window prompts for it.
- If the user declines UAC, print "Administrator permission was not given, so nothing was changed." and exit 1.
- Build the argument string in a pure function, `Get-ElevationArguments`, so it can be unit-tested.

### 9.1 Host: share a folder (admin)
1. **Folder.** Prompt if `-Path` is missing. Trim spaces and quotes, and turn `D:` into `D:\`. Validate with a pure function, `Test-SharePath`, which returns `{ Ok, Reason, FullPath, IsDriveRoot }`:
   - the folder must exist; resolve it to a full path
   - it must be a local drive path (`^[A-Za-z]:\\`); reject UNC paths
   - reject the system drive root and anything under `%windir%`
   - for the root of a non-system drive, warn: "This shares the whole D: drive. Setting permissions on a large drive can take a few minutes." Then ask for confirmation.
2. **Share name.** The default is the folder name with these characters removed: `\ / : * ? " < > | [ ] + = ; ,`. Cap it at 80 characters. If it ends up empty, use `Shared`. A drive root gives `Drive<Letter>`, for example `DriveD`. Prompt with the default (`Share name other PCs will see [Media]`). Validate with `^[^\\/:*?"<>|]{1,80}$`.
3. **Share account.** Validate the username: 1-20 characters, none of `\ / [ ] : ; | = , + * ? < > @ "`, and not ending in `.`.
   - **Refuse** (section 4) if the name is the current user's own account, or if an account with that name exists **without** the marker. Ask for a different `-UserName` instead.
   - All inputs (folder, share name, account, password) are collected and checked before anything changes, so a typo never leaves a half-done setup. A share name already used for a different path fails here too.
   - **If it exists (with the marker):** reuse it and enable it if disabled. If `-Password` is given, set it. Otherwise offer to set a new password (default **No**); with `-Yes` the current password is kept.
   - **If it doesn't:** take `-Password` or prompt twice. Reject empty ("Windows never allows blank passwords over the network"). Reject a `"` character, because it breaks `cmdkey`. The two entries must match. Then run `New-LocalUser -PasswordNeverExpires -AccountNeverExpires -UserMayNotChangePassword -Description '<marker>'`.
   - Add the account to Users with `Add-LocalGroupMember -SID S-1-5-32-545`, ignoring the "already a member" error (`FullyQualifiedErrorId` matches `MemberExists`).
   - **Hide it from the sign-in screen** (section 5) and print: "'shareuser' is hidden from the sign-in screen, so this PC still starts straight into your account."
4. **Network type.** For each `Get-NetConnectionProfile`:
   - `Public`: ask "Network 'X' is set to Public, which hides this PC and blocks sharing. Set it to Private? Only do this on a network you trust (home/office)." If yes, run `Set-NetConnectionProfile -InterfaceIndex <i> -NetworkCategory Private`. If no, warn that other PCs won't reach the share over it.
   - `DomainAuthenticated`: leave it alone and note that it is managed by IT.
   - `Private`: OK.
5. **Firewall.** For each of the two group IDs, run `Get-NetFirewallRule -Group <id>`, keep only the rules whose `Profile` includes `Private` or `Any`, and pipe them to `Enable-NetFirewallRule`. Don't touch Public-only or Domain-only rules.
6. **Services.** For `LanmanServer`, `FDResPub` and `fdPHost`: if the startup type isn't Automatic, set it to Automatic, and start the service if it isn't running. A failure is a warning, not an abort.
7. **Share.**
   - If a share with that name already exists for a **different** path, fail: "A share named 'X' already exists for <path>. Run again with a different -ShareName."
   - If it exists for the **same** path, run `Grant-SmbShareAccess -AccountName "<PC>\<user>" -AccessRight Change` (or `Read`) `-Force`.
   - Otherwise run `New-SmbShare -Name -Path -Description 'Shared with ShareDoctor'` with `-ChangeAccess` (or `-ReadAccess` when `-ReadOnly`) set to `"<PC>\<user>"` only.
8. **Folder permissions.** Run `icacls "<path>" /grant "<PC>\<user>:(OI)(CI)M"`, with `RX` instead of `M` for read-only. A non-zero exit code is a warning ("drives formatted FAT32/exFAT have no permissions - that is fine"), not a failure.
9. **Summary.** Print:
   - `\\<PCNAME>\<Share>`, and `\\<IP>\<Share>` for each IPv4 address (excluding `127.*` and `169.254.*`)
   - `username: <PCNAME>\<user>`
   - `password: the one you just chose (tick "Remember my credentials")`
   - "Easiest: run ShareDoctor on the other PC and choose 2 (Connect)."

Host must be **idempotent**: running it again for the same folder succeeds without creating duplicates.

### 9.2 Connect: open a shared folder (normal window)
1. If the window is elevated, warn that drives mapped from an admin window usually don't show in File Explorer (UAC split token), and ask whether to continue (default **No**).
2. Prompt for the target and share if they are missing. Strip leading backslashes. The UNC path is `\\<target>\<share>`.
3. **Resolve** the name with `[System.Net.Dns]::GetHostAddresses`. If nothing comes back, fail: "This PC cannot find 'X' on the network. Use its IP address instead (Host mode prints it)..."
4. **Port check.** TCP 445 with a 3-second timeout (`TcpClient.BeginConnect` plus `WaitOne`). If it's closed, fail with the advice for code 53.
5. **Old connections.** Run `Get-SmbMapping` and keep entries whose `RemotePath` matches `\\<target>\*`. List them and offer to disconnect them (`net use <LocalPath or RemotePath> /delete /y`), because they cause error 1219.
6. **Username.** The default is `<target>\<UserName>`. If the typed name contains no `\` or `@`, prefix it with `<target>\`. Take the password from `-Password` or a prompt; if it's empty, show the advice for code 1327.
7. **Save the credential.** Run `cmdkey /add:<target> /user:<user> /pass:<pw>`, then clear the plain-text variable. Tell the user it's saved in Windows Credential Manager. The credential is tied to the exact name or IP typed, so the user should keep using the same one.
8. **Test access** with `Test-ShareAccess` (section 9.5). On failure, show the advice. For sign-in errors (5, 86, 1326, 1327, 1330, 1331, 1909), offer to delete the saved credential (`cmdkey /delete:<target>`).
9. **Drive letter.** Use `-DriveLetter` if given. Otherwise, unless `-NoDriveLetter` is set, offer the first free letter from `Z` down to `E`, skipping existing drives and persistent mappings. Map it with `net use X: \\target\share /persistent:yes`.
10. Open File Explorer at the drive or UNC path, unless `-NoOpen` is set.

### 9.3 Diagnose (read-only: must never change anything)
- Prompt for an optional target and share, unless `-Yes` is set.
- Each check yields a result object: `{ Area, Check, Status = Ok|Warn|Fail|Info, Detail, Fix }`.
- Results print as console text by default, or as JSON with `-Json`: one object `{ Version, ComputerName, OsCaption, OsBuild, Results }`, where `Results` is the array of result objects. In JSON mode nothing else is written to the console.
- Exit 0 if there are no `Fail` results, otherwise 3.

Checks:
1. **This PC:** OS caption and build, PC name, IPv4 addresses. Warn on `169.254.*` ("did not get an address from the router").
2. **Network type** for each profile: `Public` is a Fail, with the fix "Settings > Network & internet > your network > Private, or run Host mode".
3. **Firewall groups:** count the inbound rules with a Private or Any profile, and how many are enabled. Fail if none are enabled, Warn if only some are, OK if all are.
4. **Third-party firewall:** query `Get-CimInstance -Namespace root/SecurityCenter2 -ClassName FirewallProduct` (client Windows only; ignore errors). Warn for each product found, with the fix "allow local network / file and printer sharing in its settings".
5. **Services:** `LanmanServer`, `LanmanWorkstation` and `FDResPub` should be running. Fail otherwise, explaining what each one is for.
6. **Own account type:** run `Get-LocalUser $env:USERNAME`.
   - `PrincipalSource` of `MicrosoftAccount`: Warn ("other PCs must use your email address and its password; a PIN does not work over the network; a ShareDoctor share account avoids this").
   - Local account: Info ("accounts with no password can never be used over the network").
   - Not found: Info ("work/school or domain account").
7. **Shares on this PC:** list shares not ending in `$`, with their path and access list (`Get-SmbShareAccess`). If a share grants only Everyone, Warn: "Modern Windows PCs will not connect as a guest, so they need a real account here - run Host mode for this folder." If not elevated, Info: "Run ShareDoctor as administrator to list this PC's shares."
8. **ShareDoctor accounts:** find local users with the marker description. Report whether each is enabled and whether it is hidden from the sign-in screen (Warn if not hidden).
9. **Target** (if given): resolve the name, then check port 445.
   - With a share name: `Test-ShareAccess`, giving the code and advice.
   - Without one: run `net view \\<target>`. Exit 0 lists the shares. Otherwise, use the first number in the output (`(\d{1,5})`) as the error code and show its advice.
10. **Summary:** a numbered list of fixes for every Fail and Warn.

The unit tests must assert that Diagnose never calls any cmdlet starting with `Set-`, `New-`, `Enable-`, `Disable-`, `Remove-`, `Grant-`, `Add-` or `Start-`.

### 9.4 Remove: stop sharing (admin)
1. Without `-ShareName`, list the shares not ending in `$` and prompt for one.
2. Ask "Stop sharing 'X' (<path>)? Your files are not touched." If yes, run `Remove-SmbShare -Force`, then `icacls "<path>" /remove:g "<PC>\<user>"`.
3. If the share account exists **and** its description equals the marker, offer (default **No**) to delete it with `Remove-LocalUser`, and remove its `UserList` registry value. Never delete an account without the marker. Keep the account (and say why) while another share still grants it access.
   If there is no share with that name, warn, still offer the account step, and exit 1.
4. Firewall and network-type changes stay. They are standard Windows settings, and the README says so.

### 9.5 Shared helpers
- `Test-ShareAccess($unc)`: call `[System.IO.Directory]::EnumerateFileSystemEntries($unc).GetEnumerator().MoveNext()`. On an exception, unwrap `InnerException` while the exception is a `System.Management.Automation.RuntimeException`.
  - If `(HResult -band 0xFFFF0000) -eq 0x80070000`, the code is `HResult -band 0xFFFF`.
  - Otherwise, `UnauthorizedAccessException` gives 5.
  - Anything else gives -1, along with the message.
  - Return `{ Code, Message }`, where 0 means access works.
- `Resolve-Target`, `Test-Port445`, `Get-FreeDriveLetter`, `Get-DefaultShareName`, `Test-SharePath`, `Test-UserNameValid`, `Test-ShareNameValid`, `Get-ElevationArguments`, `Get-FirewallGroupState`, `Invoke-Native`, `Confirm-Step` (respects `-Yes`), and `ConvertTo-Plain` (SecureString to string, used only for the `cmdkey` call and validation).

---

## 10. Error code to advice (UI copy, use verbatim)

| Code(s) | Advice text |
|---|---|
| 0 | Access works. |
| 5 | Access denied: the account used is not allowed into this share or folder. On the PC with the files, run ShareDoctor option 1 (Host) for this folder, then connect with the share account it creates. |
| 51, 53, 1231, 1232 | The other PC cannot be reached for file sharing. Check that it is switched on, on the same network (not a guest Wi-Fi, which usually keeps devices apart), its network is set to Private, and File and Printer Sharing is allowed (Host mode does both). Try the IP address instead of the name. Third-party antivirus firewalls can also block this. |
| 64 | The connection dropped part-way. Usually third-party antivirus/firewall software or an unstable network. |
| 67 | The PC answered, but it has no share with that name. Check the spelling (run Diagnose on that PC to list its shares). |
| 86 | Wrong password for that account. |
| 1219 | You are already connected to that PC with a different username, and Windows allows only one per PC. Disconnect the old connection (Connect mode offers this) or sign out and back in, then try again. |
| 1272 | The other PC only offers guest (no password) access, and this PC refuses guest connections for security. Run ShareDoctor option 1 (Host) on the other PC so it has a proper share account, then connect with that account. |
| 1326 | Unknown username or wrong password. Use the share account as PCNAME\username. For a Microsoft account, use the full email address and the account password - a PIN does not work over the network. |
| 1327 | Account restriction - most often the account has no password. Windows never allows blank-password accounts over the network. Give it a password, or use the ShareDoctor share account. |
| 1330 | The password for that account has expired. Sign in on the PC with the files and set a new one (Host mode can do this). |
| 1331 | That account is disabled on the PC with the files. Run Host mode there again to re-enable it. |
| 1909 | That account is locked after too many wrong passwords. Wait about 10 minutes, or unlock it on the PC with the files. |
| other | `Windows error <code>: <message>` (or `Windows error <code>.` with no message) |

---

## 11. Output style

- Section header: a blank line, then `== Title` in cyan.
- Status lines, indented two spaces: `[ OK ]` green, `[WARN]` yellow, `[FAIL]` red. Info lines are indented 9 spaces.
- Plain English and short sentences, written for non-technical users. Address the user as "you". In messages, say "the PC that has the files" / "the other PC", not "host" / "client".
- Never print passwords.

---

## 12. Security notes (document in the README too)

- The share account is a standard user, not an admin. It is hidden from the sign-in screen, its password never expires (it is a shared key, by design), and it can't change its own password.
- Share permission is granted to the share account only, never to Everyone.
- The network type is changed to Private only after the user confirms.
- The `cmdkey /pass:` argument is briefly visible in the process list. This is an accepted trade-off; Credential Manager is the standard store.
- Remove mode cleans up everything ShareDoctor created, apart from the standard firewall and network settings.

---

## 13. Testing

### 13.1 Lint
`Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1` must return nothing. The settings exclude only:
- `PSAvoidUsingWriteHost`: this is an interactive console tool.
- `PSUseShouldProcessForStateChangingFunctions`: the tool uses its own `Confirm-Step`.
- `PSAvoidUsingConvertToSecureStringWithPlainText`: tests only.

### 13.2 Parse check
Parse `ShareDoctor.ps1` with `[System.Management.Automation.Language.Parser]::ParseFile` under **both** `powershell.exe` (5.1) and `pwsh`, with zero errors. Also check that the file contains no non-ASCII bytes.

### 13.3 Unit tests: `tests/Unit.Tests.ps1` (Pester 5)
Safe on any Windows PC: no admin rights and no system changes. Dot-source the script in `BeforeAll`, and **mock every state-changing cmdlet and native call** (`Invoke-Native`, `New-LocalUser`, `Set-NetConnectionProfile`, the registry cmdlets, and so on). Cases:

- **Get-ErrorAdvice:** every code in section 10 returns its text. An unknown code with a message returns `Windows error N: msg`.
- **Get-DefaultShareName:** `D:\` (root) gives `DriveD`. `D:\My Media [old]` gives `My Media old`. A 100-character name is cut to 80. Only invalid characters gives `Shared`.
- **Test-SharePath:** rejects a UNC path, a missing folder, the system drive root and `%windir%\System32`. Accepts a temp folder. Sets `IsDriveRoot` for a non-system drive root (mock `$env:SystemDrive`, or test the pure parts).
- **Test-UserNameValid / Test-ShareNameValid:** valid and invalid examples, including length limits and a trailing dot.
- **Get-ElevationArguments:** values are quoted, `D:\` becomes `"D:\\"`, switches are passed, and **the password is never included**.
- **Test-ShareAccess mapping:** throw exceptions carrying HResults `0x80070005`, `0x80070035`, `0x80070043`, `0x800704F8` and `0x8007052E`, and get 5, 53, 67, 1272 and 1326. A `MethodInvocationException` wrapper is unwrapped.
- **Host flow (all mocked, -Yes, -Password):**
  - `New-LocalUser` is called once, with the marker description.
  - The account is added to the group with SID S-1-5-32-545.
  - The UserList registry value is written as 0.
  - `New-SmbShare` is called with `ChangeAccess = '<PC>\shareuser'` and **no Everyone**.
  - `-ReadOnly` uses `ReadAccess`, and icacls gets `RX`.
  - An existing share with the same path leads to `Grant-SmbShareAccess`, not `New-SmbShare`. An existing share with a different path throws.
  - A Public profile leads to `Set-NetConnectionProfile`; DomainAuthenticated doesn't.
- **Host never touches Windows security settings:** assert `Should -Invoke -Times 0` for `Set-SmbServerConfiguration`, `Set-SmbClientConfiguration`, `Enable-WindowsOptionalFeature`, and for `Set-LocalUser` / `Remove-LocalUser` on any name other than the share account.
- **Connect flow (mocked):**
  - Username prefixing: `bob` becomes `PC\bob`; `PC\bob` and `a@b.com` are unchanged.
  - `cmdkey` is called with `/add:<target>`.
  - Access code 1326 with -Yes leads to `cmdkey /delete`.
  - The free-letter picker skips used letters.
  - `-NoDriveLetter` means no `net use X:`, and `-NoOpen` means no Explorer.
- **Diagnose (mocked):**
  - A Public profile, a disabled firewall group and a stopped service each give a Fail.
  - It never calls any of the forbidden verbs (section 9.3).
  - `-Json` output parses with `ConvertFrom-Json`.
  - The exit code is 3 when there is a Fail, and 0 when everything is clean.
- **Remove (mocked):** it deletes an account only when the marker matches, and also removes the UserList value.

### 13.4 Integration test: `tests/Integration.Tests.ps1` (`-Tag Integration`)
Needs admin and **makes real changes**. It runs in CI on `windows-latest`, which is elevated. On a developer PC, run it **only with the maintainer's explicit OK**. It uses SMB loopback to the same machine:

1. Create a temp folder containing `hello.txt`, and a random password as a SecureString.
2. Run `ShareDoctor.ps1 -Mode Host -Yes -Path <temp> -ShareName SDTest -UserName sdtest -Password <pw>`. Expect exit 0, and check that:
   - the share exists
   - the account exists with the marker description
   - the UserList value is 0
   - the folder's access list contains `<PC>\sdtest`
   - the share access list does not contain Everyone.
3. Run Host again with the same arguments: expect exit 0 (idempotent) and still one share.
4. Run `-Mode Connect -Yes -Computer $env:COMPUTERNAME -ShareName SDTest -UserName sdtest -Password <pw> -NoDriveLetter -NoOpen`. Expect exit 0, and `Test-ShareAccess` returns 0.
5. Run `-Mode Diagnose -Yes -Json -Computer $env:COMPUTERNAME -ShareName SDTest`. The JSON has no Fail for the share access check.
6. Run `-Mode Remove -Yes -ShareName SDTest -UserName sdtest`. The share, the account and the UserList value are all gone.
7. `AfterAll` **always** cleans up, even after a failure: `Remove-SmbShare`, `Remove-LocalUser`, `cmdkey /delete`, the registry value and the temp folder.

If loopback with alternate credentials turns out unreliable on the runner, fall back to `New-SmbMapping -RemotePath -UserName -Password` for step 4's access test, and record that in `docs/TESTING.md`.

### 13.5 Manual test matrix: `docs/TESTING.md`
Two-PC behaviour and the startup screen can't be automated. Test machines:
- Windows 10 22H2, with a passwordless local account and auto sign-in
- Windows 11 24H2 or later, with a passwordless local account and auto sign-in
- optionally, a PC signed in with a Microsoft account.

| # | Case | Expected |
|---|---|---|
| M1 | Host on Win11, then restart | Boots straight to the desktop. **No account picker, no password** (G2, critical). |
| M2 | Win10 runs Connect to the Win11 share, then restarts | The drive reconnects with no prompt. |
| M3 | The reverse direction (Win11 connects to Win10) | Works. |
| M4 | A `-ReadOnly` share | Can read, can't write. |
| M5 | Share a whole non-system drive (`D:\`) | Works, with the warning shown. |
| M6 | Diagnose on a PC whose network is Public, then run Host | A Fail with its fix, then OK. |
| M7 | Old-style setup (password-protected sharing off, Everyone share), then Diagnose from the other PC | Explains the guest refusal (1272 or 5) correctly. |
| M8 | Wrong password in Connect | 1326/86 advice; removing the saved credential works. |
| M9 | Connect by IP instead of name | Works. |
| M10 | Remove, including the account | No share, no account, nothing on the sign-in screen. |
| M11 | Non-English Windows (if available) | All checks work. |
| M12 | Third-party antivirus installed | Diagnose warns. |

Record the date, Windows build, result and notes for each run.

---

## 14. CI and release

### `.github/workflows/ci.yml`
Runs on pushes and pull requests, on `runs-on: windows-latest`:
1. Checkout.
2. `Install-Module Pester -MinimumVersion 5.5 -Force -SkipPublisherCheck -Scope CurrentUser` and `Install-Module PSScriptAnalyzer -Force -Scope CurrentUser`. Do this in both `powershell` and `pwsh` shells, because Windows PowerShell ships the old Pester 3.4, so import with `Import-Module Pester -MinimumVersion 5.5`.
3. Lint (13.1).
4. Parse check and ASCII check (13.2), under both shells.
5. Unit tests under both shells.
6. Integration tests (13.4) under `powershell` (5.1), with `-Tag Integration`.
7. Upload Pester results as an artifact.

### `.github/workflows/release.yml`
Triggered by tags matching `v*`:
1. Run the same checks as CI.
2. Fail if `$ShareDoctorVersion` in the script doesn't equal the tag without its `v`.
3. Run `build/Build-Release.ps1`, which builds `dist/ShareDoctor-vX.Y.Z.zip` containing `ShareDoctor.ps1`, `ShareDoctor.cmd`, `README.md` and `LICENSE`, with CRLF preserved.
4. Create a GitHub Release with the zip attached, using the tag's `CHANGELOG.md` section as the notes.

### Issue template (`bug_report.md`)
Ask for:
- the Windows version (from `winver`)
- which PC it is (has the files / wants the files)
- what they tried
- the output of `ShareDoctor.ps1 -Mode Diagnose -Json` (mention they can blank out PC names).

---

## 15. README contents (user-facing)
In this order:
1. The problem
2. Why it happens (short)
3. What ShareDoctor does (the table of 4 options)
4. "Will it add a login screen to my PC?" (No, with the explanation from section 5)
5. What it deliberately doesn't do (section 4, briefly)
6. Quick start: unzip on both PCs, right-click `ShareDoctor.cmd` > Properties > Unblock, option 1 on the PC with the files, option 2 on the other PC, option 3 if anything fails
7. Command-line examples
8. The error code table
9. Undo everything
10. Requirements
11. Status
12. License

---

## 16. Roadmap (after v0.2.0)
- Code signing, so users don't need Unblock and SmartScreen stays quiet. Apply to SignPath Foundation, which offers free signing for open-source projects.
- A winget package.
- Optional hardening: deny local sign-in for the share account (`SeDenyInteractiveLogonRight` via `secedit`).
- Save the credential for both the PC name and its IP in Connect.
- A simple GUI wrapper (WinForms or WPF).
- Translations of the UI text.

---

## 17. Acceptance criteria for v0.2.0
- [ ] Every mode behaves as in section 9; Host and Remove elevate automatically.
- [ ] `-Yes`, `-Password`, `-Json`, `-NoOpen`, `-NoDriveLetter` and the exit codes work as in section 8.
- [ ] Dot-sourcing the script runs nothing.
- [ ] The section 4 constraints hold, and the unit tests assert them.
- [ ] Lint is clean; parsing is clean under 5.1 and 7; the source is ASCII-only with CRLF.
- [ ] Unit tests pass under 5.1 and 7; the integration test passes on `windows-latest`.
- [ ] Manual case M1 (no sign-in screen after Host) passes on a real Windows 11 and Windows 10 PC.
- [ ] README, CHANGELOG and TESTING.md are up to date; tagging `v0.2.0` produces a release zip.
