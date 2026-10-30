# Instalación paso a paso

> ⚠️ Sin garantía. Borra los discos. Haz primero la copia de seguridad de la flash.

Necesitas:
* El DNS-340L con el firmware de D-Link (probado con 1.08b01) y acceso **SSH como root**.
* 4 discos (el script está pensado para 4 × WD40EFRX; ajusta `SECTORES` y `generar-gpt.sh` para otros).
* Un PC con Linux o **WSL** (Ubuntu/Debian/Kali) para compilar y preparar Debian.
* Una memoria USB en **FAT32** (tabla MBR, una partición).
* Recomendado: adaptador serie de 3,3 V ([consola-serie.md](consola-serie.md)).

## 1. Copia de seguridad

En el firmware de D-Link, Administración → Redes → SSH: activar. Entrar como `admin` y pasar a root.

```sh
cd /mnt/HD/HD_a2          # o la carpeta de una memoria USB
mkdir flash
for i in $(grep -o '^mtd[0-9]*' /proc/mtd); do dd if=/dev/$i of=flash/$i.bin; done
md5sum flash/*
```

Guarda esa carpeta fuera del NAS. Con ella se puede volver al firmware de D-Link.

## 2. Compilar (en el PC)

```sh
sudo apt install git gcc-arm-linux-gnueabi make bc bison flex libssl-dev u-boot-tools \
     device-tree-compiler autoconf cpio fakeroot gdisk
kernel/compilar-nucleo.sh      # → build/uImage  (≤ 4 MiB)
initrd/compilar-initrd.sh      # → build/uInitrd (≤ 3 MiB)
cd instalacion && ./generar-gpt.sh   # → gpt_disco[1-4]_{inicio,final}.bin
```

Copia también `build/mdadm/mdadm` y `build/e2fsprogs/b/misc/mke2fs` junto a `instalar-nas.sh`
(el arranque v2 ya los incluye; son necesarios si instalas desde el sistema de prueba v1).

## 3. Grabar núcleo y arranque

### Desde el firmware de D-Link (sin consola serie)

Con `uImage` y `uInitrd` en una memoria USB, como root:

```sh
cat /proc/mtd | head -4        # mtd1 = "uImage", mtd2 = "ramdisk"
flash_eraseall /dev/mtd1 && nandwrite -p /dev/mtd1 uImage
flash_eraseall /dev/mtd2 && nandwrite -p /dev/mtd2 uInitrd
dd if=/dev/mtd0 bs=131072 count=8 2>/dev/null | md5sum   # U-Boot intacto: compárala con tu copia
```

⚠️ **Nunca `mtd0`.** Comprueba con `dd … | md5sum` que lo leído coincide con lo escrito
(relleno a 2048 bytes con `FF`).

### Desde U-Boot (consola serie y TFTP)

Probar sin grabar:
```
setenv ipaddr 192.168.1.250; setenv serverip <IP_del_PC>
tftpboot 0xa00000 uImage; tftpboot 0xf00000 uInitrd; bootm 0xa00000 0xf00000
```
Grabar:
```
tftpboot 0x2000000 uImage;  nand erase 0x500000 0x500000; nand write.e 0x2000000 0x500000 0x400000
tftpboot 0x2000000 uInitrd; nand erase 0xa00000 0x500000; nand write.e 0x2000000 0xa00000 0x300000
```

## 4. Preparar Debian (en el PC)

```sh
sudo apt install debootstrap qemu-user-binfmt binfmt-support debian-archive-keyring
ls /proc/sys/fs/binfmt_misc/ | grep qemu-arm      # debe existir, con la marca F
sudo USUARIO=tu_usuario bash debian/preparar-debian-dns340l.sh
```

Resultado: `~/dns340l-debian.tar.gz` (~100 MB). Debian 13 armhf mínimo con systemd, SSH, `mdadm`,
`smartmontools`, `sudo`, actualizaciones automáticas, red por DHCP, español, Europe/Madrid, servicio del
ventilador y apagado por el microcontrolador.

## 5. Instalar en los discos

Copia en la raíz de la memoria USB (FAT32): `dns340l-debian.tar.gz` (sin descomprimir), `instalar-nas.sh`,
`mdadm`, `mke2fs` y los 8 ficheros `gpt_disco*.bin`. Crea también un fichero vacío llamado **`RESCATE`**.

Arranca el NAS (entrará en modo rescate), conéctate por Telnet a `192.168.1.250` y:

```sh
mount -t vfat /dev/sde1 /mnt/usb    # la memoria suele ser sde (los discos son sda-sdd)
cd /mnt/usb
sh instalar-nas.sh                   # escribe BORRAR para confirmar
```

El script localiza los 4 discos por su tamaño, escribe las tablas GPT, crea `md0` (RAID 1), `md1` (RAID 1)
y `md2` (RAID 5), los formatea e instala Debian en `md0`. El RAID 5 se sincroniza después en segundo plano
(10–15 horas con 4 × 4 TB).

## 6. Primer arranque

Borra `RESCATE` de la memoria (o quítala) y reinicia.

```sh
ssh tu_usuario@<IP>                  # MAC de eth0: 02:d3:40:4c:00:01
sudo dpkg-reconfigure -plow unattended-upgrades
cat /proc/mdstat
```
