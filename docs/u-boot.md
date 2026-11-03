# DNS-340L U-Boot

`U-Boot 2011.12 (Mar 10 2014 - 11:53:29) Marvell version: v2011.12 2013_Q1.2 (ALPHA U-BOOT : 1.5)`

Analysis of the `mtd0` image (Marvell boot header v1, loaded at address 0).

## Factory boot command

U-Boot has no saved variables: it uses the built-in ones and, if `bootcmd` is missing, sets this one:

```
nand read.e 0xa00000 0x500000 0x400000     # 4 MiB from mtd1 (kernel)
nand read.e 0xf00000 0xa00000 0x300000     # 3 MiB from mtd2 (ramdisk)
bootm 0xa00000 0xf00000
```

Default `bootargs`: `root=/dev/ram console=ttyS0,115200`.
This project uses that command as it is: it is enough to write our kernel and our boot program to `mtd1` and
`mtd2`.

**Memory limit:** U-Boot always places the initrd at `0xF00000`. The decompressed kernel (`_end` in
`System.map`) plus the zImage with its device tree must stay below that address, otherwise Linux discards the
initrd and panics. `kernel/compilar-nucleo.sh` checks it (the v4 kernel exceeded it and left unit 1 unable to
boot until it was recovered through the serial console).

## Useful facts

* **Internal registers** at `0xf1000000` (the device tree must use that address).
* Legacy kernel boot (`bootm`, ATAGs): the device tree is **appended to the zImage**
  (`CONFIG_ARM_APPENDED_DTB`, `CONFIG_ARM_ATAG_DTB_COMPAT`).
* Available commands: `usb`, `fatload`, `ext2load`, `ide`, `diskboot`, `tftpboot`, `nand`, `rcvr`…
* Maximum command length: **1024** characters.
* `usbActive`: U-Boot only scans one of the two rear USB ports. On unit 1, with `usbActive=1` it did not see
  the stick; with `setenv usbActive 0` + `usb reset` it did.

## Environment variables

* Area: NAND **`0x400000`**, size **`0x80000`** (512 KiB), a single block with a CRC32 at the start.
* Empty from the factory (all `FF`).
* Writing a valid environment from Linux (D-Link firmware, `nandwrite`) with a marker in `bootargs` was tried:
  **U-Boot ignored it** (the marker did not appear in `/proc/cmdline`). Cause not confirmed (possibly an ECC
  difference between D-Link's Linux driver and U-Boot, or reading disabled).
* `herramientas/borrar_env.c` erases **only** those 4 blocks, with fixed checks, in case the area needs to be
  returned to its factory state.
* **Conclusion:** do not rely on saved variables. The factory boot command is the reliable path.

## Marvell recovery mode (not available)

The recovery code (`rcvr`) loads `/multiware.img` from USB (FAT or ext2) or over TFTP. The automatic trigger
checks a "recovery button" GPIO (class 17 in the board table), but the `RD-88F6710_ALpha_DNS340L` table
**defines only one GPIO** (class 2, pin 24). Therefore **no button triggers the recovery** (holding reset at
power-on does nothing); it can only be started with the `rcvr` command from the serial console.

## Interrupting the boot

Disassembly of `abortboot` in D-Link's U-Boot (1.08b01):

* **Only the `1` key interrupts** the countdown. Space is ignored and **any other key ends it and boots at once**.
* With the U-Boot variables erased (`*** Warning - bad CRC, using default environment`) the delay is **0**
  (`Hit any key to stop autoboot:  0`). Even so, on unit 1 it was possible to get in by pressing `1`
  repeatedly right at power-on, with the adapter's TXD on the correct RX point (see
  [serial-console.md](serial-console.md)).

Alternative without touching the flash: boot through the serial console (BootROM UART mode) a copy of your own
U-Boot with the delay changed to 5 seconds. It runs from memory; after power-off everything is as before.

```sh
python3 herramientas/uboot-con-espera.py flash/mtd0.bin u-boot-espera5.kwb   # from your mtd0 backup
sudo apt install u-boot-tools
sudo kwboot -t -p -B 115200 -b u-boot-espera5.kwb /dev/ttyUSB0
# power on the NAS; after the transfer (~1-2 min), press 1 during the countdown -> Marvell>>
```
