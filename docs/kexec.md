# kexec on the DNS-340L

The flash kernel starts Debian's kernel with `kexec`. On the DNS-340L three preparations are needed before
`kexec -e`; without them the new kernel hangs or boots with stale data. `initrd/init` always does them.

**Tested on both units on 3 November 2026**: by hand from the flash test system (to the same 6.12 kernel and
to Debian's `6.12.107+deb13-armmp`), and automatically with the v6 `uInitrd` written to flash.

Debian's initramfs also needs the `ARRAY` lines in `/etc/mdadm/mdadm.conf` (without them it does not find the
system RAID and does not boot). `instalar-nas.sh` adds them and regenerates the initramfs.

## 1. Turn on all SoC clocks

When it boots, the flash kernel gates the clocks it does not use (`clk: Disabling unused clocks`): audio, the
two internal SATA ports, SD and TDM. U-Boot leaves them all on. If the new kernel touches a block without a
clock before enabling it, it hangs without any message.

```sh
devmem 0xf1018220 32 $(( $(devmem 0xf1018220) | 0x5282823F ))
```

`0xF1018220` is the Armada 370 `clock-gating-control` register; the mask gathers the bits from
`drivers/clk/mvebu/armada-370.c` (0–5, 9, 15, 17, 23, 25, 28, 30). With Linux 6.12 the value goes from
`0xB1CC423E` to `0xF3CEC23F`.

## 2. Erase the stale copy of the device tree

The flash kernel has its device tree appended to the zImage. Its decompressor merges it with U-Boot's ATAGs
(command line `root=/dev/ram` and initrd at `0xF00040`) and leaves it in RAM right after the kernel (at
`0x00D31320` on the tested unit). If the zImage started with kexec decompresses to the same place, its
decompressor relocates itself into that area, finds the stale copy right at its `_edata`, takes it for an
appended device tree and **discards the one passed by kexec**: you see the old command line and
`Initramfs unpacking failed: invalid magic`. Clearing the ATAGs at `0x100` does not help.

`herramientas/borrar-fdt-viejo.c` searches `/dev/mem` for exact copies of `/sys/firmware/fdt` and erases
their magic number (`borrar-fdt-viejo SI`). The tree prepared by kexec is different and is not touched.

## 3. Bring the network down before the jump

`mvneta` (the Armada 370 network driver) has no shutdown function: if the interfaces stay up, the hardware
keeps copying packets into memory that now belongs to the new kernel. `kexec -e` without `-x` brings the
interfaces down before jumping; do not use `-x` except for debugging.

## Debugging without a serial console

* The flash kernel's `netconsole` sends to `255.255.255.255` from `192.168.1.250`: Windows drops those
  packets, but Wireshark sees them (filter `udp.port == 6666`, *Follow → UDP Stream*). When a console
  registers, it replays the whole kernel log from the start.
* Debian's initramfs loads `netconsole` too (added by `instalar-nas.sh`, see `/etc/initramfs-tools/modules`).
* `echo 1 > /sys/module/kernel/parameters/initcall_debug` prints each device as it is shut down.
* `kexec -e -x` keeps the network up until `Bye!` (only to see the last messages of the old kernel).
* The project's kexec accepts `-d`: the `KEXEC_DEBUG` flag, which Linux 6.12 rejects, has been removed.
* To check whether the jump itself works without depending on Linux: a minimal image with a zImage header that
  sends the power-off command to the microcontroller (`FA 03 03 01 01 01 FB` on UART1).

## Known issues

* The SoC's software reset (`reboot: Restarting system`) leaves the board hung. Debian reboots through the
  microcontroller (`MCUReset`, see [microcontroller.md](microcontroller.md)), but a reboot issued by the
  kernel itself (e.g. after a *kernel panic* with `panic=`) still hangs.

After kexec, the front USB 3.0 (Etron EJ168) works (`Host supports USB 3.0 SuperSpeed`).
