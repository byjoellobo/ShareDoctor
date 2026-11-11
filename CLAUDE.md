# ShareDoctor - working notes for Claude Code

ShareDoctor is a single-file PowerShell tool. It makes Windows 10/11 network file sharing work by giving the PC with the files a hidden, password-protected share account. Other PCs save that account's password once. It also diagnoses "Access denied" problems in plain English.

**Read `SPEC.md` before any change. It is the source of truth.** If the repo still contains the v0.1.0 prototype, bring it up to the spec rather than starting over, unless the maintainer asks for a rewrite.

## Never do these (SPEC.md section 4)
If a request would break any of these, stop and explain instead of implementing it:
- Enable guest/insecure guest access, change SMB signing or encryption, or enable SMB1.
- Change the user's own account (password, PIN, type, groups or sign-in).
- Create or accept blank-password accounts.
- Grant share access to Everyone, or make the share account an admin.
- Share the system drive root or anything under `%windir%`.
- Add a visible sign-in-screen account. The share account must stay hidden so passwordless PCs still boot straight to the desktop.

## Code rules
- Must run on **Windows PowerShell 5.1**: no `??`, no ternary, no `&&` / `||`, no `-Parallel`.
- **ASCII-only** source; **CRLF** for `.ps1` and `.cmd` (see `.gitattributes`).
- Everything stays in `ShareDoctor.ps1`. The main entry is guarded so dot-sourcing loads functions only.
- Never match localized text. Use SIDs, firewall group resource IDs and numeric error codes.
- Native commands go through `Invoke-Native`.
- Keep logic in small, pure, testable functions. Every new behaviour gets a unit test.
- UI text is plain English for non-technical users. Never print passwords.

## One-time setup on this PC
```powershell
Install-Module Pester -MinimumVersion 5.5 -Force -SkipPublisherCheck -Scope CurrentUser
Install-Module PSScriptAnalyzer -Force -Scope CurrentUser
```

## Testing

**Safe to run anytime. Nothing on this PC changes:**
```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-Pester -Path .\tests\Unit.Tests.ps1 -Output Detailed
powershell -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5; Invoke-Pester -Path .\tests\Unit.Tests.ps1 -Output Detailed"
.\ShareDoctor.ps1 -Mode Diagnose -Yes -Json      # read-only
```
Also run the parse and ASCII check from SPEC.md section 13.2 under both `powershell` and `pwsh`.

**These change this PC (they create an account, a share, and firewall/network settings):**
Host mode, Remove mode, and `Invoke-Pester -Path .\tests\Integration.Tests.ps1 -Tag Integration` (admin).
- **Ask the maintainer before running any of them here.** Prefer letting CI run the integration test.
- If they are run, make sure cleanup ran afterwards. Check that no `SDTest` share and no `sdtest` account are left behind.

**Two-PC and startup tests are manual** (SPEC.md section 13.5). Give the maintainer the steps, then record their results in `docs/TESTING.md`.

## Git workflow
- `main` is always releasable. Use a branch per change (`feat/...`, `fix/...`) and merge when lint and tests pass.
- Commit messages: Conventional Commits (`feat:`, `fix:`, `test:`, `docs:`, `ci:`, `refactor:`).
- Before every commit, run lint and the unit tests. Don't commit if either fails.
- To release:
  1. Bump `$ShareDoctorVersion` in `ShareDoctor.ps1`.
  2. Add a `CHANGELOG.md` section.
  3. Commit, then tag `vX.Y.Z` and push the tag. `release.yml` builds the zip and publishes the GitHub Release.
- Don't push or tag unless the maintainer asks.
