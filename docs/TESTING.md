# Testing ShareDoctor

ShareDoctor is checked in three layers. The first two run automatically on every push; the third needs two real PCs and is done by hand.

| Layer | What | Where it runs | Changes the PC? |
|---|---|---|---|
| 1 | Lint, parse, ASCII and CRLF checks, unit tests, build tests | CI on Windows PowerShell 5.1 and PowerShell 7, and any developer PC | No |
| 2 | Integration test over SMB loopback | CI (`windows-latest`, elevated) | **Yes** |
| 3 | Manual two-PC test matrix (below) | Real Windows 10 and 11 PCs | Yes |

## 1. Safe checks (run anytime)

Nothing on the PC changes. One-time setup:

```powershell
Install-Module Pester -MinimumVersion 5.5 -Force -SkipPublisherCheck -Scope CurrentUser
Install-Module PSScriptAnalyzer -Force -Scope CurrentUser
```

Then, from the repository folder:

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1   # must print nothing
Invoke-Pester -Path .\tests\Unit.Tests.ps1, .\tests\Build.Tests.ps1 -Output Detailed
powershell -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5; Invoke-Pester -Path .\tests\Unit.Tests.ps1, .\tests\Build.Tests.ps1 -Output Detailed"
.\ShareDoctor.ps1 -Mode Diagnose -Yes -Json                                        # read-only
```

- **`tests/Unit.Tests.ps1`** dot-sources the script, so only its functions load. Every command that could change the PC is mocked, and `Read-Host` is mocked to fail, so `-Yes` can never prompt. It covers SPEC.md section 13.3: the error advice texts, name and path validation, the elevation command line (never the password), error-code mapping, the Host, Connect, Diagnose and Remove flows, and the hard constraints from SPEC.md section 4. Diagnose is checked twice for "never changes anything": at run time with mocks, and statically by walking every function Diagnose can reach. It also checks that every `.ps1`, `.psd1` and `.cmd` file parses, is ASCII-only and uses CRLF.
- **`tests/Build.Tests.ps1`** builds the release zip into a temporary folder and checks its contents, its byte-for-byte copies (CRLF kept), the checksum, the version and the CHANGELOG section.

## 2. Integration test (makes real changes)

`tests/Integration.Tests.ps1` (Pester tag `Integration`) runs ShareDoctor for real against the same PC over SMB loopback, using `127.0.0.1`: Host twice (to show it is idempotent), Connect, an access test as the share account, Diagnose `-Json`, then Remove. It creates the account `sdtest`, the share `SDTest` and a saved sign-in for `127.0.0.1`, and Host may set networks to Private, enable firewall rules and start services. `AfterAll` always cleans up, each step on its own, and only deletes the account if it carries the ShareDoctor marker. It also puts network types, firewall rules and services back from a snapshot taken before the test. CI then checks that no `SDTest` share and no `sdtest` account are left behind.

It is **skipped** unless `CI=true` (set by GitHub Actions) or `SHAREDOCTOR_RUN_INTEGRATION=1`. It refuses to run without admin rights, or when an `sdtest` account, an `SDTest` share or a saved sign-in for `127.0.0.1` already exists. On a developer PC, run it only with the maintainer's explicit OK:

```powershell
# Elevated PowerShell, on a PC where these changes are acceptable
$env:SHAREDOCTOR_RUN_INTEGRATION = '1'
Invoke-Pester -Path .\tests\Integration.Tests.ps1 -Tag Integration -Output Detailed
Remove-Item Env:SHAREDOCTOR_RUN_INTEGRATION
Get-SmbShare -Name SDTest -ErrorAction SilentlyContinue; Get-LocalUser -Name sdtest -ErrorAction SilentlyContinue   # both must print nothing
```

### Loopback note: the SPEC.md section 13.4 fallback is in use

When a PC connects to its own shares, Windows signs in with the caller's own logon token and ignores sign-ins saved with `cmdkey` (NTLM's local-call shortcut). So on the CI runner, Connect's own access test signs in as the runner's admin account, which is not on the share, and gets "Access denied" (error 5). This was seen on `windows-latest` on 2026-11-11.

The test therefore:

1. checks Connect's flow from its output: it finds the PC, sees port 445 open, saves the sign-in, and, if it fails at all, fails only with error 5;
2. signs in explicitly as the share account with `New-SmbMapping -RemotePath -UserName -Password`, as SPEC.md section 13.4 allows, then reads a file and writes one over SMB;
3. runs Diagnose while that session is open, and expects no failure for the share access check.

Between two PCs the saved sign-in is used. That part is covered by manual cases M2, M3, M8 and M9.

### Results

| Date | Runner | Result | Notes |
|---|---|---|---|
| 2026-11-11 | GitHub `windows-latest` (Windows PowerShell 5.1) | Pass, 6 of 6 | Explicit sign-in fallback in use (see above). The runner has no Private-only firewall rules, so Host left the firewall alone and warned, as designed. Nothing left behind. |
| 2026-11-11 | GitHub `windows-latest` (Windows PowerShell 5.1) | Pass, 6 of 6 | After the review fixes: connects to `127.0.0.1`, restores settings, and `icacls /L` sets the folder permission (the share account reads and writes over SMB). Every cleanup step succeeded. |

## 3. Manual two-PC test matrix

The startup screen and real two-PC connections can't be automated. Test machines:

- Windows 10 22H2 with a passwordless local account and automatic sign-in
- Windows 11 24H2 or later with a passwordless local account and automatic sign-in
- Optionally, a PC signed in with a Microsoft account

| # | Case | Expected |
|---|---|---|
| M1 | Host on Windows 11, then restart | Boots straight to the desktop. **No account picker and no password** (goal G2, critical). |
| M2 | Windows 10 runs Connect to the Windows 11 share, then restarts | The drive reconnects with no prompt. |
| M3 | The reverse direction (Windows 11 connects to Windows 10) | Works. |
| M4 | A `-ReadOnly` share | Can read, can't write. |
| M5 | Share a whole non-system drive (`D:\`) | Works, with the warning shown. |
| M6 | Diagnose on a PC whose network is Public, then run Host | A Fail with its fix, then OK. |
| M7 | Old-style setup (password-protected sharing off, Everyone share), then Diagnose from the other PC | Explains the guest refusal (1272 or 5) correctly. |
| M8 | Wrong password in Connect | 1326/86 advice; removing the saved sign-in works. |
| M9 | Connect by IP address instead of name | Works. |
| M10 | Remove, including the account | No share, no account, nothing on the sign-in screen. |
| M11 | Non-English Windows (if available) | All checks work. |
| M12 | Third-party antivirus installed | Diagnose warns. |

### How to run M1 (the critical one)

1. On a Windows 11 PC whose own account has no password and signs in automatically, unzip the release and run `ShareDoctor.cmd`, option **1**. Share any folder with a new password.
2. Restart the PC.
3. **Pass:** it goes straight to the desktop, with no account picker and no password box. **Fail:** anything else; note what the sign-in screen shows.
4. Run option **3** (Diagnose) and check that "ShareDoctor accounts" says the account is hidden from the sign-in screen.
5. Repeat on Windows 10.

### Results

Record each run here: the date, the Windows build (from `winver`), the result and any notes.

| # | Date | Windows build | Result | Notes |
|---|---|---|---|---|
| M1 | | | Not run yet | |
| M2 | | | Not run yet | |
| M3 | | | Not run yet | |
| M4 | | | Not run yet | |
| M5 | | | Not run yet | |
| M6 | | | Not run yet | |
| M7 | | | Not run yet | |
| M8 | | | Not run yet | |
| M9 | | | Not run yet | |
| M10 | | | Not run yet | |
| M11 | | | Not run yet | |
| M12 | | | Not run yet | |
