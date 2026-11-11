# Changelog

All notable changes to ShareDoctor are recorded here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and ShareDoctor uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-11-11

The first public release. It rebuilds the v0.1.0 prototype to the full specification in [SPEC.md](SPEC.md).

### Added

- New options: `-Password` (for automation), `-NoDriveLetter`, `-NoOpen` and `-Json`.
- Fixed exit codes: `0` success, `1` error, `2` cancelled or a required value missing with `-Yes`, `3` Diagnose found a problem.
- `-Yes` never prompts. It uses defaults where there are some, and fails with exit code 2 when a required value is missing.
- `-Mode Diagnose -Json` prints one JSON object (version, PC name, Windows version and every check result) and nothing else.
- Diagnose checks the ShareDoctor share accounts (enabled, hidden from the sign-in screen) and warns about shares that only allow Everyone, in any display language.
- Diagnose keeps going when one check breaks, and prints a numbered list of fixes at the end.
- Remove keeps the share account while another share still uses it.
- When Host reuses a share that still lets Everyone in, it offers to remove Everyone, so only the share account has access.
- More than 200 unit tests, an integration test over SMB loopback, CI on Windows PowerShell 5.1 and PowerShell 7, and automatic release builds with SHA-256 checksums.

### Changed

- Host mode checks every input (folder, share name, account, password) before it changes anything, so a typo never leaves a half-done setup.
- Host mode refuses to reuse an account ShareDoctor did not create, or your own account.
- Host mode only enables firewall rules for Private networks. Rules that also cover Public networks are left alone, so sharing never opens up on a cafe or hotel Wi-Fi.
- The share account's marker is now `File sharing account (created by ShareDoctor)`.
- Host mode waits for the administrator window and returns its exit code.
- Host mode hides the share account's name from the sign-in screen before it creates the account, and stops if it can't, so a visible account never appears.
- Long console lines wrap at word boundaries, under the text they belong to.

### Fixed

- Host mode could not create the share account: the old marker was longer than the 48 characters Windows allows in an account description.
- The Windows-folder check no longer blocks folders whose names only start with the same letters, such as `C:\WindowsBackups`.
- Mapped network drives are refused as share folders, like network paths.
- Folders reached through a junction or symbolic link are refused, because the link could point into the Windows folder.
- A relative `-Path` (such as `.\Media`) now works when Host asks for admin rights.
- Connect no longer saves a wrong password: it refuses passwords containing `"` with an explanation, and keeps a trailing backslash intact on Windows PowerShell 5.1.
- With `-Json`, menu option 3 still prints its results.
- Diagnose tells a work, school or domain account apart from a failed account lookup.

## [0.1.0] - 2026-11-11

Prototype: one PowerShell script and a launcher. Not published as a release.

[Unreleased]: https://github.com/byjoellobo/ShareDoctor/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/byjoellobo/ShareDoctor/releases/tag/v0.2.0
