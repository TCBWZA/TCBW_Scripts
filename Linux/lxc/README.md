# Linux / lxc

Scripts for managing Proxmox LXC containers. All scripts run on the **Proxmox host**.

> **LXC UID mapping note:** Proxmox unprivileged containers map container UIDs to a host offset of 100000. Container UID **1000** appears on the host as UID **101000**. This matters if you inspect file ownership from the host side - the container's user (UID 1000) will show as 101000 in `ls -ln` output on the host.

---

## Scripts

### lxc-upgrade.sh

Updates the Proxmox host itself and then updates all LXC containers in parallel (up to 3 at a time).

**What it does:**

- Runs `apt update && apt upgrade -y && apt autoremove -y` on the Proxmox host.
- Discovers all containers via `pct list`.
- For each container:
  - If stopped, starts it temporarily and waits 60 seconds for boot.
  - Runs `apt-get update && apt-get upgrade -y && apt-get autoremove -y` inside the container via `pct exec`.
  - If `/var/run/reboot-required` exists inside the container after the update, reboots it.
- Processes up to 3 containers concurrently.
- After all containers are updated, stops any container that was started by this script (containers that were already running before the script are left running).

**Requirements:** `pct` (Proxmox host only)

```bash
./lxc-upgrade.sh
```

> Logs for each container are written to `/var/log/lxc-update-<CTID>.log` on the host.
