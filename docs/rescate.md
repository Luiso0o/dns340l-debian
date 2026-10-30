# Modo rescate y recuperación

## Modo rescate

El arranque grabado en `mtd2` entra en modo rescate si:
* no encuentra un sistema de ficheros con `LABEL=debian-raiz` y `/sbin/init`, o
* hay una memoria USB **FAT** con un fichero llamado **`RESCATE`** en la raíz, o
* la línea de órdenes del núcleo contiene `rescate`.

Señales: el **ventilador sube al máximo** al entrar en rescate y **baja a media** cuando obtiene IP por DHCP.

Qué ofrece:
* IP por DHCP en eth0/eth1 y además **192.168.1.250** / **192.168.1.251**.
* Web en `http://192.168.1.250/` con `estado.txt` (registro de arranque, red, PHY, PCIe, USB, particiones, `dmesg`) y un botón para apagar.
* **Telnet sin contraseña** (solo para red local; no exponer).
* `mdadm`, `mke2fs`, `fdisk`, `blockdev` y el resto de BusyBox.
* Copia de `estado.txt` en la primera memoria FAT (`dns340l-log.txt`) durante 15 minutos.

Ensamblar y montar el sistema a mano:
```sh
echo 'DEVICE partitions' > /run/mdadm.conf
mdadm --assemble --scan --config=/run/mdadm.conf
cat /proc/mdstat
mount -t ext4 LABEL=debian-raiz /newroot
```

## Si el núcleo no arranca

Sin núcleo funcional no hay red: hace falta la [consola serie](consola-serie.md).
Desde `Marvell>>` se puede arrancar otro núcleo por TFTP sin grabar nada
(ver [instalacion.md](instalacion.md#desde-u-boot-consola-serie-y-tftp)).

## Volver al firmware de D-Link

Con la copia de seguridad de la flash (`mtd1.bin` y `mtd2.bin`) y la consola serie:
```
tftpboot 0x2000000 mtd1.bin; nand erase 0x500000 0x500000; nand write.e 0x2000000 0x500000 0x500000
tftpboot 0x2000000 mtd2.bin; nand erase 0xa00000 0x500000; nand write.e 0x2000000 0xa00000 0x500000
```
Los discos habrá que volver a inicializarlos desde el asistente de D-Link.
