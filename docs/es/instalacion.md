# Instalación paso a paso

> ⚠️ Sin garantía. Borra los discos. Haz primero la copia de seguridad de la flash.

Necesitas:
* El DNS-340L con el firmware de D-Link (probado con 1.08b01) y acceso **SSH como root**, o una
  [consola serie](consola-serie.md).
* De 2 a 4 discos de cualquier tamaño (mejor iguales; se usa el tamaño del más pequeño).
* Un PC con Linux o **WSL** (Ubuntu/Debian/Kali) para compilar y preparar Debian.
* Una memoria USB en **FAT32** (tabla MBR, una partición). Vale una pequeña y vieja.

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
     device-tree-compiler autoconf autopoint gettext cpio fakeroot
kernel/compilar-nucleo.sh      # → build/uImage  (≤ 4 MiB; comprueba el límite de memoria)
initrd/compilar-initrd.sh      # → build/uInitrd (≤ 3 MiB) y build/sfdisk
```

Para la instalación hacen falta además, junto a `instalar-nas.sh`, las herramientas estáticas `build/sfdisk`,
`build/mdadm/mdadm` y `build/e2fsprogs/b/misc/mke2fs`.

## 3. Grabar núcleo y arranque

### Desde el firmware de D-Link (sin consola serie)

Con `uImage` y `uInitrd` en una memoria USB, como root:

```sh
cat /proc/mtd | head -4        # mtd1 = "uImage", mtd2 = "ramdisk"
flash_eraseall /dev/mtd1 && nandwrite -p /dev/mtd1 uImage
flash_eraseall /dev/mtd2 && nandwrite -p /dev/mtd2 uInitrd
head -c $(stat -c %s uImage)  /dev/mtd1 | md5sum   # debe coincidir con md5sum uImage
head -c $(stat -c %s uInitrd) /dev/mtd2 | md5sum   # debe coincidir con md5sum uInitrd
```

⚠️ **Nunca `mtd0`** (U-Boot).

### Desde U-Boot (consola serie)

Ver [consola-serie.md](consola-serie.md#recuperar-un-equipo-desde-u-boot): cargar los dos ficheros de una
memoria FAT32 con `fatload`, probarlos en RAM con `bootm` y grabarlos con `nand erase` + `nand write.e`.

### Desde Debian (para actualizarlos más adelante)

```sh
sudo apt install mtd-utils
sudo flash_erase /dev/mtd2 0 0
sudo nandwrite -p /dev/mtd2 uInitrd
sudo head -c $(stat -c %s uInitrd) /dev/mtd2 | md5sum
```

## 4. Preparar Debian (en el PC)

```sh
sudo apt install git debootstrap qemu-user-binfmt binfmt-support debian-archive-keyring curl
git clone https://github.com/Luiso0o/dns340l-debian.git
cd dns340l-debian/debian
sudo USUARIO=tu_usuario NOMBRE=nas1 MAC=02:d3:40:4c:01:00 bash preparar-debian-dns340l.sh
```

Tarda 10–20 minutos y al final pide la contraseña del usuario. Resultado: `~/dns340l-debian.tar.gz`
(~270 MB): Debian 13 armhf mínimo con systemd, SSH, `mdadm`, `smartmontools`, `sudo`, actualizaciones
automáticas, DHCP, el núcleo oficial de Debian preparado para kexec, el servicio del ventilador, apagado y
reinicio por el microcontrolador, Cockpit y Tailscale.

* `COCKPIT=0`, `TAILSCALE=0` o `NUCLEO=0` delante de `bash` para no instalar el panel web, Tailscale o el
  núcleo de Debian.
* **Varios NAS en la misma red:** prepara un `.tar` por equipo, cada uno con su `NOMBRE` y su `MAC`. El árbol
  de dispositivos trae la misma MAC para todos los DNS-340L; Debian la cambia con un fichero `.link`. Sin
  `MAC`, se genera una al azar (el script la muestra al final para reservarla en el router).
* El identificador de máquina (`/etc/machine-id`) y las claves SSH se generan en el primer arranque de cada equipo.
* Los repositorios van por HTTPS: algunos cortafuegos cortan las descargas de paquetes por HTTP.

## 5. Instalar en los discos

Copia en la raíz de la memoria USB (FAT32): `dns340l-debian.tar.gz` (sin descomprimir), `instalar-nas.sh`,
`sfdisk`, `mdadm`, `mke2fs` y un fichero vacío llamado **`RESCATE`** (obliga a entrar en modo rescate, para
que no se arranque un sistema viejo de los discos).

Enciende el NAS con los discos y la memoria en un puerto trasero. Entrará en modo rescate; abre una shell en
la consola serie (Intro) o conéctate por Telnet (a la IP del DHCP o a `192.168.1.250`):

```sh
cd /mnt/usb
sh instalar-nas.sh                   # escribe BORRAR para confirmar
```

El script localiza los discos SATA de las bahías (de 2 a 4, de cualquier tamaño; nunca la memoria USB),
muestra el esquema y el espacio útil, y solo continúa si escribes `BORRAR`. Después:

* Escribe en todos los discos la misma tabla GPT, calculada sobre el más pequeño: sistema 20 GiB, intercambio
  2 GiB y datos con el resto, dejando 100 MiB libres al final (para poder sustituir un disco por otro algo
  más pequeño).
* Crea el RAID 1 del sistema, el RAID 1 de intercambio y el de datos (**RAID 5** con 3 o 4 discos, **RAID 1**
  con 2), los formatea y descomprime Debian.
* Añade las líneas `ARRAY` al `mdadm.conf` de Debian y regenera su initramfs (sin ellas el initramfs de Debian
  no encuentra el RAID del sistema), con `netconsole` para poder ver los mensajes de arranque con Wireshark.
* Si el RAID de datos superaría **16 TiB** (límite del núcleo de 32 bits, por ejemplo con 4 × 8 TB), reduce la
  partición de datos y lo avisa antes de borrar nada.

El RAID de datos se sincroniza después en segundo plano (unas 30 horas con 4 × 4 TB).

**Reinstalar solo el sistema.** En discos ya instalados con este proyecto (etiquetas `debian-raiz`, `swap` y
`datos`), `SOLO_SISTEMA=1 sh instalar-nas.sh` formatea solo el RAID del sistema y vuelve a instalar Debian: el
intercambio y los datos se conservan y no hay que reconstruir el RAID de datos. Probado en el equipo 1.

## 6. Primer arranque

Quita la memoria USB (o el fichero `RESCATE`) y apaga y enciende. El arranque de la flash ensambla los RAID y
salta con kexec a Debian. Busca el NAS en el router por la MAC que elegiste y entra:

```sh
ssh tu_usuario@<IP>
uname -r                             # núcleo de Debian: 6.12.x+deb13-armmp
cat /proc/mdstat
sudo apt update && sudo apt full-upgrade
sudo tailscale up
```

Cockpit: `https://<IP>:9090`. No publiques los puertos 9090 ni 22 en el router: usa Tailscale desde fuera.

## Actualizaciones del núcleo y protección

El hook `zz-dns340l` (en `/etc/kernel/postinst.d/` y `/etc/initramfs/post-update.d/`) copia el núcleo de Debian
más reciente, su initramfs y el árbol de dispositivos a `/boot/dns340l/`, guardando los anteriores como
`*.old`. Antes de cada salto, el arranque de la flash anota en `/boot/dns340l/intento` qué núcleo prueba
(`actual` o `anterior`), y el servicio `dns340l-arranque-ok` borra el fichero cuando Debian arranca:

| `/boot/dns340l/intento` | Qué hace al encender |
|---|---|
| no existe | arranca el núcleo actual |
| `actual` | el actual falló: arranca el anterior (`*.old`) |
| `anterior` | fallaron los dos: modo rescate |

Para volver a probar el núcleo actual: `sudo rm /boot/dns340l/intento` (o desde el rescate). Al instalar un
núcleo nuevo con `apt`, el fichero se borra solo.

## Apagado y reinicio

`poweroff` y `reboot` funcionan con normalidad: un script de apagado de systemd pide al microcontrolador que
corte la corriente (`DeviceShutdown`) o que reinicie la placa entera (`MCUReset`). El reinicio por software
del propio procesador deja la placa colgada, así que el núcleo no debe reiniciar por su cuenta. Mientras se
reconstruye un RAID, Cockpit bloquea el apagado normal: usa `systemctl start poweroff.target` o
`systemctl start reboot.target`.
