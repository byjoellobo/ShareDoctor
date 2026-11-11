# ShareDoctor

Make file sharing between Windows 10 / 11 PCs on the same network work again, without switching off Windows security.

## The problem

You share a folder or drive and turn off "password protected sharing", like you could on older Windows. The other PC then just says **Access denied** or **Windows cannot access \\\\PC\\Share** and gives no reason.

## Why it happens

- Newer Windows versions refuse password-less ("guest") connections to shared folders, and Windows 11 24H2 tightened this further. Turning off password-protected sharing on the host doesn't help any more, and Windows doesn't tell you that's the cause.
- Accounts with **no password** can never be used over the network.
- If you sign in with a **Microsoft account**, other PCs need your email address and account password. Your PIN won't work.
- Networks marked **Public** hide the PC and block sharing.
- Third-party antivirus firewalls often block it as well.

## What ShareDoctor does

| Option | Run it on | What it does |
|---|---|---|
| **1 Share a folder** (Host) | the PC that has the files | Creates a standard (non-admin) account just for sharing and hides it from the sign-in screen. Shares the folder with that account only, sets your network to Private (it asks first), turns on File and Printer Sharing and Network Discovery in the firewall, and starts the sharing services. Then it prints exactly what to type on the other PC. |
| **2 Connect** | the PC that wants the files | Checks the other PC can be reached, saves the share account's password once in Windows Credential Manager, tests access, maps a drive letter that survives restarts, and opens it. |
| **3 Diagnose** | either PC | Read-only. Checks network type, firewall, services and your account type, lists shares, tests a connection, and **explains the actual reason** in plain words. |
| **4 Stop sharing** (Remove) | the host | Removes the share and its folder permission. It can also delete the share account. Your files are never touched. |

### Will it add a login screen to my PC?

No. Your own account isn't touched, so if it has no password it stays that way. The share account is used only by other PCs over the network, and ShareDoctor hides it from the sign-in screen, so the PC still starts straight to your desktop. Its password is typed once on each other PC and saved there.

### What it deliberately doesn't do

It doesn't turn guest access back on or weaken how connections are secured. Those protections keep other people on your Wi-Fi out of your files, and fixes that depend on switching them off tend to break with the next Windows update. ShareDoctor uses a normal password-protected account, which works on every current version of Windows.

## Quick start

1. Download the zip from Releases and unzip it on **both** PCs.
2. Right-click `ShareDoctor.cmd`, then **Properties > Unblock** (only once; this clears the "downloaded from the internet" flag).
3. **On the PC with the files:** double-click `ShareDoctor.cmd`, choose **1**, and give the folder and a password. Windows will ask for admin permission.
4. **On the other PC:** double-click `ShareDoctor.cmd`, choose **2**, type the PC name (or IP) and share name it printed, then the password.

If something fails, choose **3** on either PC. It tells you what's wrong.

## Command line

```powershell
.\ShareDoctor.ps1 -Mode Host -Path 'D:\Media' -ShareName Media            # add -ReadOnly for read-only
.\ShareDoctor.ps1 -Mode Connect -Computer OFFICE-PC -ShareName Media -DriveLetter M
.\ShareDoctor.ps1 -Mode Diagnose -Computer OFFICE-PC -ShareName Media
.\ShareDoctor.ps1 -Mode Remove -ShareName Media
```

`-UserName` changes the share account's name (default `shareuser`). `-Yes` answers yes to confirmations.

## Errors it explains

| Code | Meaning |
|---|---|
| 5 | Access denied. The account isn't allowed into that share or folder. |
| 53 / 51 / 1231 | The PC can't be reached: it's off, on a different network or guest Wi-Fi, set to Public, or blocked by a firewall. |
| 67 | The PC answered, but no share has that name. |
| 86 / 1326 | Wrong username or password (or a PIN was used instead of the Microsoft account password). |
| 1219 | Already connected to that PC under a different username. |
| 1272 | The other PC only offers guest access, which this PC refuses. Run Host mode there. |
| 1327 | Account restriction, usually a blank password. |
| 1330 / 1331 / 1909 | Password expired, account disabled, or account locked out. |

## Undo everything

- On the host: option **4** removes the share, and optionally the account. Firewall and network-type changes are standard Windows settings and can stay.
- On a client: `net use M: /delete` removes the drive, and `cmdkey /delete:OFFICE-PC` removes the saved password.

## Requirements

Windows 10 or 11 (Home, Pro, Enterprise or Education) with the built-in Windows PowerShell 5.1. Admin rights are needed only on the host.

## Status

v0.2.0. If something doesn't work, please open an issue with your Windows version and the **Diagnose** output.

## License

MIT. See [LICENSE](LICENSE).
