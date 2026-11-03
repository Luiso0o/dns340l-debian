# Modo rescate y recuperación

## Modo rescate

El arranque grabado en `mtd2` entra en modo rescate si:
* no encuentra un sistema de ficheros con `LABEL=debian-raiz`, o el núcleo de Debian en `/boot/dns340l/`, o
* no llegaron a arrancar ni el núcleo actual ni el anterior de Debian (`/boot/dns340l/intento`), o
* hay una memoria USB **FAT** con un fichero llamado **`RESCATE`** en la raíz (probado en el equipo 1), o
* la línea de órdenes del núcleo contiene `rescate`.

La consola serie muestra el motivo (`*** … ***`). Señales: el **ventilador sube al máximo** al entrar en
rescate y **baja a media** cuando obtiene IP por DHCP.

Qué ofrece:
* IP por DHCP en eth0/eth1 y además **192.168.1.250** / **192.168.1.251**.
* Web en `http://192.168.1.250/` con `estado.txt` (registro de arranque, red, PHY, PCIe, USB, particiones,
  `dmesg`) y un botón para apagar.
* **Telnet sin contraseña** (solo para red local; no exponer) y una shell en la consola serie (pulsar Intro).
* `mdadm`, `mke2fs`, `fdisk`, `blockdev`, `kexec`, `nandwrite` y el resto de BusyBox (`flash_eraseall` va
  incluido en las compilaciones posteriores al 3-11-2026; antes, la flash se graba desde U-Boot).
* El registro de arranque en la primera memoria FAT (`dns340l-arranque.txt`) y una copia de `estado.txt`
  (`dns340l-log.txt`), que se actualiza durante 15 minutos.

Ensamblar y montar el sistema a mano:
```sh
echo 'DEVICE partitions' > /run/mdadm.conf
mdadm --assemble --scan --config=/run/mdadm.conf
cat /proc/mdstat
mount -t ext4 $(findfs LABEL=debian-raiz) /newroot
```

Los nombres de los RAID pueden cambiar de un arranque a otro (`md125`, `md126`, `md127`…): usa siempre las
etiquetas.

## Si el núcleo de la flash no arranca

Sin núcleo funcional no hay red: hace falta la [consola serie](consola-serie.md). Desde `Marvell>>` se puede
arrancar otro núcleo desde una memoria USB sin grabar nada, y grabarlo cuando funcione (ver
[consola-serie.md](consola-serie.md#recuperar-un-equipo-desde-u-boot)).

## Volver al firmware de D-Link

Con la copia de seguridad de la flash (`mtd1.bin` y `mtd2.bin`) en una memoria FAT32 y la consola serie:
```
setenv usbActive 0; usb reset
fatload usb 0:1 0x2000000 /mtd1.bin; nand erase 0x500000 0x500000; nand write.e 0x2000000 0x500000 0x500000
fatload usb 0:1 0x2000000 /mtd2.bin; nand erase 0xa00000 0x500000; nand write.e 0x2000000 0xa00000 0x500000
```
Los discos habrá que volver a inicializarlos desde el asistente de D-Link.
