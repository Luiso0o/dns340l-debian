# Rescue mode and recovery

## Rescue mode

The boot program written to `mtd2` enters rescue mode if:
* it does not find a file system with `LABEL=debian-raiz`, or Debian's kernel in `/boot/dns340l/`, or
* both the current and the previous Debian kernel failed to boot (`/boot/dns340l/intento`), or
* there is a **FAT** USB stick with a file called **`RESCATE`** in its root (tested on unit 1), or
* the kernel command line contains `rescate`.

The serial console shows the reason (`*** … ***`). Signals: the **fan goes to full speed** when rescue mode
starts and **drops to medium** once it gets an IP address over DHCP.

What it offers:
* IP address over DHCP on eth0/eth1, plus **192.168.1.250** / **192.168.1.251**.
* Web page at `http://192.168.1.250/` with `estado.txt` (boot log, network, PHY, PCIe, USB, partitions,
  `dmesg`) and a power-off button.
* **Telnet without a password** (local network only; never expose it) and a shell on the serial console
  (press Enter).
* `mdadm`, `mke2fs`, `fdisk`, `blockdev`, `kexec`, `nandwrite` and the rest of BusyBox (`flash_eraseall` is
  included from builds made after 3 November 2026; before that, write the flash from U-Boot).
* The boot log on the first FAT stick (`dns340l-arranque.txt`) and a copy of `estado.txt`
  (`dns340l-log.txt`), refreshed for 15 minutes.

Assembling and mounting the system by hand:
```sh
echo 'DEVICE partitions' > /run/mdadm.conf
mdadm --assemble --scan --config=/run/mdadm.conf
cat /proc/mdstat
mount -t ext4 $(findfs LABEL=debian-raiz) /newroot
```

The RAID device names may change between boots (`md125`, `md126`, `md127`…): always use the labels.

## If the flash kernel does not boot

Without a working kernel there is no network: you need the [serial console](serial-console.md). From
`Marvell>>` you can boot another kernel from a USB stick without writing anything, and write it once it works
(see [serial-console.md](serial-console.md#recovering-a-unit-from-u-boot)).

## Going back to the D-Link firmware

With the flash backup (`mtd1.bin` and `mtd2.bin`) on a FAT32 stick and the serial console:
```
setenv usbActive 0; usb reset
fatload usb 0:1 0x2000000 /mtd1.bin; nand erase 0x500000 0x500000; nand write.e 0x2000000 0x500000 0x500000
fatload usb 0:1 0x2000000 /mtd2.bin; nand erase 0xa00000 0x500000; nand write.e 0x2000000 0xa00000 0x500000
```
The disks then have to be initialised again from the D-Link wizard.
