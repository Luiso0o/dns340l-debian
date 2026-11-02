# U-Boot del DNS-340L

`U-Boot 2011.12 (Mar 10 2014 - 11:53:29) Marvell version: v2011.12 2013_Q1.2 (ALPHA U-BOOT : 1.5)`

Análisis de la imagen de `mtd0` (cabecera de arranque Marvell v1, carga en la dirección 0).

## Orden de arranque de fábrica

U-Boot no trae variables guardadas: usa las compiladas y, si falta `bootcmd`, pone esta:

```
nand read.e 0xa00000 0x500000 0x400000     # 4 MiB de mtd1 (núcleo)
nand read.e 0xf00000 0xa00000 0x300000     # 3 MiB de mtd2 (ramdisk)
bootm 0xa00000 0xf00000
```

`bootargs` por defecto: `root=/dev/ram console=ttyS0,115200`.
Este proyecto aprovecha esta orden tal cual: basta con grabar nuestro núcleo y nuestro arranque en `mtd1` y `mtd2`.

## Datos útiles

* **Registros internos** en `0xf1000000` (el árbol de dispositivos debe usar esa dirección).
* Núcleo legado (`bootm`, ATAG): el árbol de dispositivos va **añadido al final del zImage** (`CONFIG_ARM_APPENDED_DTB`, `CONFIG_ARM_ATAG_DTB_COMPAT`).
* Órdenes disponibles: `usb`, `fatload`, `ext2load`, `ide`, `diskboot`, `tftpboot`, `nand`, `rcvr`…
* Longitud máxima de una orden: **1024** caracteres.
* `usbActive=1`: U-Boot solo explora uno de los dos controladores USB 2.0.

## Variables de entorno

* Zona: NAND **`0x400000`**, tamaño **`0x80000`** (512 KiB), un único bloque con CRC32 al principio.
* De fábrica está **vacía** (todo `FF`).
* Se probó a escribir desde Linux (firmware de D-Link, `nandwrite`) un entorno válido con una marca en
  `bootargs`: **U-Boot lo ignoró** (la marca no apareció en `/proc/cmdline`). Causa no confirmada
  (posible diferencia de ECC entre el controlador de Linux de D-Link y U-Boot, o lectura desactivada).
* `herramientas/borrar_env.c` borra **solo** esos 4 bloques, con comprobaciones fijas, por si se necesita
  devolver la zona a su estado de fábrica.
* **Conclusión:** no depender de variables guardadas. Lo fiable es la orden de arranque de fábrica.

## Modo de recuperación de Marvell (no disponible)

El código de recuperación (`rcvr`) carga `/multiware.img` de un USB (FAT o ext2) o por TFTP. La activación
automática comprueba un GPIO de "botón de recuperación" (clase 17 en la tabla de la placa), pero la tabla
`RD-88F6710_ALpha_DNS340L` **solo define un GPIO** (clase 2, pin 24). Por tanto, **ningún botón activa la
recuperación**; solo se puede lanzar con la orden `rcvr` desde la consola serie.

## Interrumpir el arranque

Desensamblado de `abortboot` en el U-Boot de D-Link (1.08b01):

* **Solo la tecla `1` interrumpe** la cuenta atrás. El espacio se ignora y **cualquier otra tecla la
  termina y arranca en el acto**.
* Con las variables de U-Boot borradas (`*** Warning - bad CRC, using default environment`) la espera
  es **0** (`Hit any key to stop autoboot:  0`) y no hay forma de interrumpir: U-Boot no mira el puerto serie.

Solución sin tocar la flash: arrancar por la consola serie (modo UART del BootROM) una copia de tu propio
U-Boot con la espera cambiada a 5 segundos. Se ejecuta en memoria; al apagar, todo vuelve a ser como antes.

```sh
python3 herramientas/uboot-con-espera.py flash/mtd0.bin u-boot-espera5.kwb   # a partir de tu copia de mtd0
sudo apt install u-boot-tools
sudo kwboot -t -p -B 115200 -b u-boot-espera5.kwb /dev/ttyUSB0
# encender el NAS; tras la transferencia (~1-2 min), pulsar 1 durante la cuenta atrás -> Marvell>>
```
