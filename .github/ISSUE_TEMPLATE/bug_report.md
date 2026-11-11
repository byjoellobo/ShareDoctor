---
name: Bug report
about: File sharing still fails, or ShareDoctor did something unexpected
title: ''
labels: bug
assignees: ''
---

**Windows version**
Press Win+R, type `winver` and press Enter. Copy the version and build, for example "Windows 11 Home, version 24H2 (OS Build 26100.2314)".

- PC with the files:
- Other PC:

**Which PC did you run ShareDoctor on?**
- [ ] The PC that has the files
- [ ] The PC that wants the files
- [ ] Both

**What did you try?**
Which option (1 Host, 2 Connect, 3 Diagnose, 4 Remove) or which command line, and what happened.

**What did you expect to happen?**

**Diagnose output**
On the PC where it fails, open PowerShell in the ShareDoctor folder and run the line below (add `-Computer OTHER-PC -ShareName Share` to include the connection test). Paste the output here. You can blank out PC names and IP addresses.

```powershell
.\ShareDoctor.ps1 -Mode Diagnose -Json
```

```json

```

**Anything else?**
For example: antivirus software, a Microsoft account, a company or school PC, or a non-English Windows.
