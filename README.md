> **English** · [Español](README.es.md)

# Debian 13 on the D-Link ShareCenter DNS-340L

How to replace the factory firmware (abandoned since 2018, with the critical vulnerability
[CVE-2024-3273](https://nvd.nist.gov/vuln/detail/CVE-2024-3273) still unpatched) with **current Debian 13**,
running **Debian's official kernel**, **software RAID (`mdadm`)**, **SSH**, the **Cockpit** web panel and
**Tailscale**.

> ⚠️ **Disclaimer.** This project is provided **AS IS, WITHOUT WARRANTY OF ANY KIND**.
> Modifying the flash memory can brick the device and **the installation wipes the disks completely**.
> Use it at your own risk. Not affiliated with or endorsed by D-Link.
> "D-Link" and "ShareCenter" are trademarks of their respective owners.

## Status

Tested on two units on 3 November 2026.

| Component | Status |
|---|---|
| Marvell Armada 370 (1.2 GHz), 512 MiB | ✅ Linux 6.12 boots from flash with the original U-Boot |
| 4 SATA bays (Marvell 88SE9215, 6 Gbps) | ✅ |
| Network: 2 × gigabit (Marvell 88E1510 PHY) | ✅ each unit gets its own MAC address from Debian |
| USB 2.0 (both rear ports) | ✅ |
| Front USB 3.0 (Etron EJ168) | ✅ 5 Gbps with Debian's kernel (started with kexec) |
| Fan and temperatures (Weltrend microcontroller) | ✅ protocol documented, Debian service |
| Power off and reboot | ✅ `poweroff` and `reboot` go through the microcontroller |
| LEDs | ✅ power LED white/orange in `/sys/class/leds/` (`white:power`, `amber:power`); the bay LEDs are driven by the SATA controller |
| Buttons | 🟡 reset and USB copy reach Linux; the power button only powers on (it does not notify Linux) |
| Debian booted from the RAID with `kexec` (kernel v5 + boot v6) | ✅ powers on and boots Debian 13 unattended |
| Debian kernel updates with `apt` | ✅ tested: 6.12.107 → 6.12.115, prepared automatically by `zz-dns340l` |
| Cockpit (web panel, port 9090) and Tailscale | ✅ |
| Both units | ✅ unit 2 installed from scratch; unit 1 recovered through the serial console and reinstalled with `SOLO_SISTEMA=1` (keeps the data RAID) |

## How the system is laid out

```
NAND (flash)                          Disks (2-4, identical GPT; here 4 × 4 TB)
├─ mtd0  original U-Boot (untouched)  ├─ part. 1  20 GiB ─┐ RAID 1 ×4  ext4  "debian-raiz"  → Debian 13
├─ mtd1  Linux 6.12 (uImage ≤4 MiB)   ├─ part. 2   2 GiB ─┤ RAID 1 ×4  swap
└─ mtd2  boot (uInitrd ≤3 MiB)        └─ part. 3  rest   ─┘ RAID 5     ext4  "datos" → /srv/datos
```

* **U-Boot is never modified.** Its factory boot command (which ignores saved variables, see
  [docs/u-boot.md](docs/u-boot.md)) loads 4 MiB from `mtd1` and 3 MiB from `mtd2`: that is where our kernel
  and our boot program go.
* The **boot program** (`initrd/init`) plays the role of GRUB: it assembles the RAIDs, mounts
  `LABEL=debian-raiz` and jumps with **`kexec` to Debian's official kernel** (`linux-image-armmp`) stored in
  `/boot/dns340l/`. Debian **always** runs its own kernel, updated by `apt` like on a PC, without touching the
  flash. The flash kernel is only used to load it and for rescue mode. See [docs/kexec.md](docs/kexec.md) for
  what kexec needs on this board.
* If a Debian kernel fails to boot (`/boot/dns340l/intento` not removed), the next power-on tries the previous
  kernel (`*.old`); if that fails too, it enters rescue mode.
* On the serial console it shows the disks, the RAID status, the root found and, if something fails, the exact
  reason. The log is kept in `/var/log/dns340l/` and on the USB stick, if one is plugged in.
* If Debian cannot be booted, or a FAT USB stick contains a file called `RESCATE`, it enters **rescue mode**
  (Telnet, diagnostics web page, DHCP and 192.168.1.250, `mdadm`, `mke2fs`, `kexec`).

## Quick guide

1. **Back up** the whole flash from the D-Link firmware → [docs/installation.md](docs/installation.md#1-back-up-the-flash)
2. **Build** the kernel and the boot program: `kernel/compilar-nucleo.sh` and `initrd/compilar-initrd.sh`
3. **Write** `uImage` to `mtd1` and `uInitrd` to `mtd2`, from the D-Link firmware (SSH, as root) **or** from
   U-Boot with the [serial console](docs/serial-console.md)
4. **Prepare Debian** on a Linux/WSL PC: `sudo USUARIO=your_user NOMBRE=nas1 MAC=02:d3:40:4c:01:00 bash debian/preparar-debian-dns340l.sh`
5. **Install** from rescue mode: `sh instalar-nas.sh` (⚠️ wipes the disks)
6. Power cycle and log in with SSH.

Full details in **[docs/installation.md](docs/installation.md)**.

## Documentation

English is the main language; a Spanish copy is kept in [docs/es/](docs/es/) and [README.es.md](README.es.md).
Scripts, code comments and the messages shown on the NAS are in Spanish.

| | |
|---|---|
| [docs/installation.md](docs/installation.md) | Step-by-step installation |
| [docs/kexec.md](docs/kexec.md) | What kexec needs on the DNS-340L, and how to debug without a serial console |
| [docs/hardware.md](docs/hardware.md) | Components, PCIe, network, GPIO, MPP, NAND partitions, buttons, LEDs |
| [docs/serial-console.md](docs/serial-console.md) | Serial console header, adapter wiring and recovery from U-Boot |
| [docs/microcontroller.md](docs/microcontroller.md) | Weltrend WT6701 protocol (fan, power, clock) |
| [docs/u-boot.md](docs/u-boot.md) | Findings about D-Link's U-Boot |
| [docs/rescue.md](docs/rescue.md) | Rescue mode and recovery |

## Repository layout

```
kernel/        device tree, Linux 6.12 configuration and build script
initrd/        boot program (init), rescue mode and build script (BusyBox, mdadm, mke2fs, kexec)
debian/        Debian 13 armhf preparation (debootstrap), kernel hook for kexec (zz-dns340l), device tree
instalacion/   instalar-nas.sh (partitions, creates the RAIDs, installs; 2 to 4 disks of any size)
herramientas/  borrar_env.c (U-Boot variables only), nand340.c (NAND tool), borrar-fdt-viejo.c (before kexec)
docs/          documentation (docs/es/: Spanish)
```

## Known issues and next steps

* A reboot issued by the kernel itself (e.g. after a *kernel panic* with `panic=`) still hangs: only `reboot`
  from Debian goes through the microcontroller.
* While a RAID is rebuilding, Cockpit (`udisksd`) blocks the normal shutdown; use
  `systemctl start poweroff.target` or `systemctl start reboot.target`.
* The power button does not reach Linux (neither GPIO nor microcontroller) and does not power off.
* Publish `uImage` and `uInitrd` as a *release*, together with their source code.
* More than 16 TiB of disks: the data volume is currently capped; it could be split into two RAIDs.

## Credits and references

* The **DNS-327L** device tree in Linux (Andrew Andrianov), the basis of this work.
* The **dns320l-daemon** project and work on the DNS-320L: same microcontroller and protocol.
* Threads in the **Alt-F** group and the **Armbian** forum about the DNS-340L.

## License

[GPL-2.0-or-later](LICENSE). The device tree is also available under MIT, like the rest of the Linux device
trees (`GPL-2.0+ OR MIT`). Published binaries include Linux, BusyBox, mdadm and e2fsprogs (GPL-2.0); their
exact source code is published with each *release*.
