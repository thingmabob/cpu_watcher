# CPU Watcher Service

A minimal **CPU temperature and usage monitoring solution** for Arch Linux, running as a **user-level `systemd` service**.
Logs all events to `journald` and optionally sends critical desktop notifications.

---

## Features

* Alerts on **critical CPU temperature** (default: 90°C)
* Alerts on **sustained high CPU usage** (default: 95% for 20 seconds)
* Desktop notifications via `notify-send` (critical-only alerts)
* Logs all events to `journald` for traceability
* Easy installation/uninstallation as a **user-level systemd service**

---

## Installation

```bash
chmod +x cpu-watcher.sh
./cpu-watcher.sh --install
```

This will:

1. Copy the script to `~/.local/bin/cpu-watcher.sh`
2. Create the service file at `~/.config/systemd/user/cpu-watcher.service`
3. Enable and start the service immediately
4. Set it to autostart on login

**Note:** Requires `lm-sensors` and `bc` installed. Optional features depend on `notify-send` and `pidstat`.

---

## Uninstall

```bash
./cpu-watcher.sh --uninstall
```

This will:

* Stop the service
* Remove the service file
* Remove the installed script
* Disable autostart

---

## Manual Run (Debugging)

```bash
./cpu-watcher.sh --run
```

Runs the watcher in the foreground. Logs are printed to the terminal and notifications will appear if `notify-send` is available.

---

## Service Status

```bash
./cpu-watcher.sh --status
```

Or directly with `systemctl`:

```bash
systemctl --user status cpu-watcher.service
```

---

## Journald Logging

All logs are sent to `journald`. Use these commands to view or filter logs:

### View all logs

```bash
journalctl --user -u cpu-watcher.service
```

### Follow logs live

```bash
journalctl --user -u cpu-watcher.service -f
```

### Show most recent entries

```bash
journalctl --user -u cpu-watcher.service -n 50
```

### Filter by priority (errors only)

```bash
journalctl --user -u cpu-watcher.service -p err
```

### Filter by date/time

```bash
journalctl --user -u cpu-watcher.service --since "10 min ago"
journalctl --user -u cpu-watcher.service --since today
journalctl --user -u cpu-watcher.service --since "2025-09-09 14:00:00"
```

### Export logs to a file

```bash
journalctl --user -u cpu-watcher.service --since today > cpu-watcher-logs.txt
```

---

## Notes

* **Required dependencies:** `lm-sensors`, `bc`
* **Optional dependencies:** `notify-send` for desktop notifications, `pidstat` for top process monitoring
* **Cooldown mechanism** prevents repeated alerts to reduce spam
* Designed for **user-level service**, does not require root

---

## License

This project is licensed under the MIT License. See the LICENSE file for details.

---

## Author

GitHub: thingmabob

---
