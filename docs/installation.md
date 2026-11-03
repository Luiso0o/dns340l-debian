# Step-by-step installation

> ⚠️ No warranty. It wipes the disks. Back up the flash first.

You need:
* The DNS-340L with the D-Link firmware (tested with 1.08b01) and **SSH access as root**, or a
  [serial console](serial-console.md).
* 2 to 4 disks of any size (ideally identical; the smallest one sets the size).
* A PC with Linux or **WSL** (Ubuntu/Debian/Kali) to build and prepare Debian.
* A **FAT32** USB stick (MBR partition table, one partition). A small, old one is fine.

## 1. Back up the flash

In the D-Link firmware, Management → Network → SSH: enable it. Log in as `admin` and become root.

```sh
cd /mnt/HD/HD_a2          # or the folder of a USB stick
mkdir flash
for i in $(grep -o '^mtd[0-9]*' /proc/mtd); do dd if=/dev/$i of=flash/$i.bin; done
md5sum flash/*
```

Keep that folder outside the NAS. With it you can go back to the D-Link firmware.

## 2. Build (on the PC)

```sh
sudo apt install git gcc-arm-linux-gnueabi make bc bison flex libssl-dev u-boot-tools \
     device-tree-compiler autoconf autopoint gettext cpio fakeroot
kernel/compilar-nucleo.sh      # → build/uImage  (≤ 4 MiB; checks the memory limit)
initrd/compilar-initrd.sh      # → build/uInitrd (≤ 3 MiB) and build/sfdisk
```

For the installation you also need, next to `instalar-nas.sh`, the static tools `build/sfdisk`,
`build/mdadm/mdadm` and `build/e2fsprogs/b/misc/mke2fs`.

## 3. Write the kernel and the boot program

### From the D-Link firmware (no serial console)

With `uImage` and `uInitrd` on a USB stick, as root:

```sh
cat /proc/mtd | head -4        # mtd1 = "uImage", mtd2 = "ramdisk"
flash_eraseall /dev/mtd1 && nandwrite -p /dev/mtd1 uImage
flash_eraseall /dev/mtd2 && nandwrite -p /dev/mtd2 uInitrd
head -c $(stat -c %s uImage)  /dev/mtd1 | md5sum   # must match md5sum uImage
head -c $(stat -c %s uInitrd) /dev/mtd2 | md5sum   # must match md5sum uInitrd
```

⚠️ **Never `mtd0`** (U-Boot).

### From U-Boot (serial console)

See [serial-console.md](serial-console.md#recovering-a-unit-from-u-boot): load both files from a FAT32 USB
stick with `fatload`, try them in RAM with `bootm`, and write them with `nand erase` + `nand write.e`.

### From Debian (to update them later)

```sh
sudo apt install mtd-utils
sudo flash_erase /dev/mtd2 0 0
sudo nandwrite -p /dev/mtd2 uInitrd
sudo head -c $(stat -c %s uInitrd) /dev/mtd2 | md5sum
```

## 4. Prepare Debian (on the PC)

```sh
sudo apt install git debootstrap qemu-user-binfmt binfmt-support debian-archive-keyring curl
git clone https://github.com/Luiso0o/dns340l-debian.git
cd dns340l-debian/debian
sudo USUARIO=your_user NOMBRE=nas1 MAC=02:d3:40:4c:01:00 bash preparar-debian-dns340l.sh
```

It takes 10–20 minutes and asks for the user's password at the end. Result: `~/dns340l-debian.tar.gz`
(~270 MB): minimal Debian 13 armhf with systemd, SSH, `mdadm`, `smartmontools`, `sudo`, automatic updates,
DHCP, Debian's official kernel prepared for kexec, the fan service, power off and reboot through the
microcontroller, Cockpit and Tailscale.

* `COCKPIT=0`, `TAILSCALE=0` or `NUCLEO=0` before `bash` skip the web panel, Tailscale or Debian's kernel.
* **Several NAS units on the same network:** prepare one `.tar` per unit, each with its own `NOMBRE` (host
  name) and `MAC`. The device tree has the same MAC for every DNS-340L; Debian changes it with a `.link` file.
  Without `MAC`, a random one is generated and shown at the end, so you can reserve it in the router.
* The machine identifier (`/etc/machine-id`) and the SSH keys are generated on each unit's first boot.
* The repositories are configured with HTTPS: some firewalls cut package downloads over plain HTTP.

## 5. Install on the disks

Copy to the root of the USB stick (FAT32): `dns340l-debian.tar.gz` (not unpacked), `instalar-nas.sh`,
`sfdisk`, `mdadm`, `mke2fs` and an empty file called **`RESCATE`** (it forces rescue mode, so an old system on
the disks is not booted).

Power on the NAS with the disks and the stick in a rear port. It will enter rescue mode; open a shell on the
serial console (Enter) or connect with Telnet (the DHCP address, or `192.168.1.250`):

```sh
cd /mnt/usb
sh instalar-nas.sh                   # type BORRAR to confirm
```

The script finds the SATA disks in the bays (2 to 4, any size; never the USB stick), shows the layout and the
usable space, and only continues if you type `BORRAR`. Then it:

* Writes the same GPT to every disk, sized on the smallest one: system 20 GiB, swap 2 GiB and data with the
  rest, leaving 100 MiB free at the end (so a disk can be replaced by a slightly smaller one).
* Creates the system RAID 1, the swap RAID 1 and the data RAID (**RAID 5** with 3 or 4 disks, **RAID 1** with
  2), formats them and unpacks Debian.
* Adds the `ARRAY` lines to Debian's `mdadm.conf` and regenerates its initramfs (without them Debian's
  initramfs does not find the system RAID), with `netconsole` so boot messages can be seen with Wireshark.
* If the data RAID would exceed **16 TiB** (limit of the 32-bit kernel, e.g. with 4 × 8 TB), it shrinks the
  data partition and warns before wiping anything.

The data RAID then synchronises in the background (about 30 hours with 4 × 4 TB).

**Reinstalling only the system.** On disks already installed with this project (labels `debian-raiz`, `swap`
and `datos`), `SOLO_SISTEMA=1 sh instalar-nas.sh` formats only the system RAID and installs Debian again: swap
and data are kept and the data RAID does not need to rebuild. Tested on unit 1.

## 6. First boot

Remove the USB stick (or the `RESCATE` file) and power cycle. The flash boot program assembles the RAIDs and
jumps with kexec to Debian. Find the NAS in your router by the MAC you chose and log in:

```sh
ssh your_user@<IP>
uname -r                             # Debian's kernel: 6.12.x+deb13-armmp
cat /proc/mdstat
sudo apt update && sudo apt full-upgrade
sudo tailscale up
```

Cockpit: `https://<IP>:9090`. Do not forward ports 9090 or 22 in the router: use Tailscale from outside.

## Kernel updates and protection

The `zz-dns340l` hook (in `/etc/kernel/postinst.d/` and `/etc/initramfs/post-update.d/`) copies the newest
Debian kernel, its initramfs and the device tree to `/boot/dns340l/`, keeping the previous ones as `*.old`.
Before each jump the flash boot program writes which kernel it tries (`actual` or `anterior`) into
`/boot/dns340l/intento`, and the `dns340l-arranque-ok` service removes the file once Debian is up:

| `/boot/dns340l/intento` | What happens at power-on |
|---|---|
| does not exist | boots the current kernel |
| `actual` | the current one failed: boots the previous one (`*.old`) |
| `anterior` | both failed: rescue mode |

To retry the current kernel: `sudo rm /boot/dns340l/intento` (or from rescue mode). Installing a new kernel
with `apt` removes the file automatically.

## Power off and reboot

`poweroff` and `reboot` work normally: a systemd shutdown script tells the microcontroller to cut the power
(`DeviceShutdown`) or to reset the whole board (`MCUReset`). The SoC's own software reset leaves the board
hung, so the kernel must not reboot by itself. While a RAID rebuilds, Cockpit blocks the normal shutdown:
use `systemctl start poweroff.target` or `systemctl start reboot.target`.
