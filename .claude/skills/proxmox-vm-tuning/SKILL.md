---
name: Proxmox VM Tuning
description: Configure Proxmox VMs for database workloads. Covers SSD passthrough flags that can cause 10x write latency difference, disk verification, and iothread configuration.
---
# Proxmox VM Tuning

VMs running on Proxmox (or other hypervisors) can silently suffer from poor disk performance even when the host has NVMe storage. Without correct virtual disk flags, the guest OS sees the disk as a spinning drive and the I/O scheduler, filesystem, and database all make suboptimal decisions.

## The Problem

A VM on an NVMe host without SSD flags:
- Guest sees `ROTA=1` (rotational / spinning disk)
- PostgreSQL WAL write latency: **68ms** (should be < 10ms)
- SQL Server log write latency: **68ms** (should be < 10ms)
- Database throughput drops 5-10x under write-heavy workloads

## Fix: Proxmox SCSI Disk Flags

In the Proxmox UI or via CLI, set these flags on each VM's SCSI disk:

| Flag | Value | Purpose |
|------|-------|---------|
| `ssd` | `1` | Tell guest this is an SSD (sets ROTA=0) |
| `discard` | `on` | Enable TRIM/UNMAP passthrough |
| `iothread` | `1` | Dedicated I/O thread per disk (reduces latency) |

### Proxmox UI

1. Select the VM → Hardware → Hard Disk
2. Click Edit
3. Check: **SSD emulation**, **Discard**, **IO thread**
4. Click OK
5. **Reboot the VM** (flags take effect on boot)

### Proxmox CLI

```bash
# Example: VM 101, scsi0 on local-lvm
qm set 101 -scsi0 local-lvm:vm-101-disk-0,ssd=1,discard=on,iothread=1

# Reboot required
qm reboot 101
```

### qm.conf

The resulting config line in `/etc/pve/qemu-server/<vmid>.conf` should look like:

```text
scsi0: local-lvm:vm-101-disk-0,discard=on,iothread=1,size=100G,ssd=1
```

## Verification

After rebooting the VM, verify from inside the guest:

```bash
# Check rotational flag (should be 0 for SSD)
lsblk -o NAME,ROTA,DISC-MAX

# Expected output:
# NAME   ROTA DISC-MAX
# sda       0      2G    ← ROTA=0 means SSD, DISC-MAX > 0 means TRIM works
# ├─sda1    0      2G
# └─sda2    0      2G
```

If `ROTA=1`, the SSD flag is not applied. Check that you rebooted after changing the setting.

### Database-Level Verification

**PostgreSQL:**
```sql
-- Check WAL write latency (should be < 10ms)
SELECT * FROM pg_stat_wal;

-- Quick write test
\timing on
CREATE TABLE _wal_test AS SELECT generate_series(1, 100000) AS id;
DROP TABLE _wal_test;
```

**SQL Server:**
```sql
-- Check I/O latency per file
SELECT
    db_name(database_id) AS db,
    file_id,
    io_stall_write_ms / NULLIF(num_of_writes, 0) AS avg_write_latency_ms,
    io_stall_read_ms / NULLIF(num_of_reads, 0) AS avg_read_latency_ms
FROM sys.dm_io_virtual_file_stats(NULL, NULL)
ORDER BY avg_write_latency_ms DESC;
```

Write latency should be under 10ms. If it's 50ms+, the SSD flags are likely missing.

## VMware / Hyper-V

The same principle applies to other hypervisors:

- **VMware**: Use Paravirtual SCSI adapter. Thin provisioning inherits SSD characteristics from the datastore.
- **Hyper-V**: Use VHDX on SSD storage. The guest automatically detects SSD via TRIM support.

## Impact Summary

| Metric | Before (no flags) | After (ssd=1,discard=on,iothread=1) |
|--------|-------------------|--------------------------------------|
| PG WAL write latency | 68ms | 6ms |
| SQL Server log write | 68ms | 6ms |
| `lsblk ROTA` | 1 (spinning) | 0 (SSD) |
| TRIM/DISCARD | disabled | enabled |
| Batch throughput (150 streams) | unstable, load 35+ | stable, load 1.1 |
