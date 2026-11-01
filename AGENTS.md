# Instrucciones para agentes (Codex, Claude y similares)

Este archivo describe el proyecto y sus reglas para cualquier asistente de programación que trabaje
en el repositorio. Léelo entero antes de cambiar nada.

## Qué es el proyecto

Sustituir el firmware de fábrica del **D-Link ShareCenter DNS-340L** (Marvell Armada 370, 512 MiB,
4 bahías SATA, NAND de 256 MiB) por **Debian 13 (trixie) armhf** instalado en un RAID por software.

Cadena de arranque:

1. **U-Boot original** (2011.12 de Marvell, en `mtd0`). Su orden de arranque es fija e ignora las
   variables guardadas: `nand read.e 0xa00000 0x500000 0x400000; nand read.e 0xf00000 0xa00000 0x300000; bootm 0xa00000 0xf00000`.
2. **Núcleo de la flash** (`mtd1`, `uImage` ≤ 4 MiB): Linux 6.12 con el árbol de dispositivos añadido al final (*appended DTB*).
3. **Arranque de la flash** (`mtd2`, `uInitrd` ≤ 3 MiB): `initrd/init` ensambla los RAID, monta
   `LABEL=debian-raiz` y salta con `kexec` al núcleo oficial de Debian que hay en `/boot/dns340l/`.
   Si no puede, arranca Debian con el núcleo de la flash; si no hay Debian, entra en modo rescate.
4. **Debian 13** en `md0` (RAID 1 de 4 discos), intercambio en `md1`, datos en `md2` (RAID 5).

## Estructura

```
kernel/        árbol de dispositivos (.dtsi + -f1.dts), configuración de Linux 6.12, compilar-nucleo.sh
initrd/        init (arranque), rescate.sh (modo rescate), compilar-initrd.sh (BusyBox, mdadm, mke2fs, kexec estáticos)
debian/        preparar-debian-dns340l.sh (debootstrap), zz-dns340l (hook de núcleo), instalar-nucleo-debian.sh
instalacion/   instalar-nas.sh (particiona, crea RAID, instala) y generar-gpt.sh
herramientas/  borrar_env.c (borra solo la zona de variables de U-Boot)
docs/          documentación del hardware, U-Boot, consola serie, microcontrolador, instalación y rescate
```

## Compilación

* Núcleo: `kernel/compilar-nucleo.sh` → `uImage` (debe ocupar **≤ 4 MiB**, U-Boot no lee más) y
  `armada-370-dlink-dns340l.dtb`. Necesita `gcc-arm-linux-gnueabihf`, `u-boot-tools`, `bc`, `flex`, `bison`, `libssl-dev`.
* Arranque: `initrd/compilar-initrd.sh` → `uInitrd` (debe ocupar **≤ 3 MiB**). Todo estático, sin libudev.
* Debian: `sudo USUARIO=nombre bash debian/preparar-debian-dns340l.sh` en un PC Linux con
  `debootstrap` y `qemu-user-binfmt`.
* Comprueba siempre los tamaños tras compilar: superar el límite deja el equipo sin arrancar.
* El código de `initrd/` se ejecuta con **BusyBox `sh` (ash)**: nada de construcciones exclusivas de bash.

## Reglas de seguridad (obligatorias)

* **Nunca** escribas, borres ni propongas escribir en `mtd0` (U-Boot). Nada de `flash_eraseall /dev/mtd0`
  ni `nand erase` sobre `0x0–0x4FFFFF`. La única excepción documentada es `herramientas/borrar_env.c`,
  que solo toca `0x400000–0x47FFFF` con comprobaciones.
* Las particiones `image.cfs`, `rescue`, `config` y `mydlink` se mantienen de solo lectura en el árbol de dispositivos.
* El bloque defectuoso conocido de la NAND está en `0x920000`: usa siempre `nand read.e`/`write.e`
  (o `nandwrite` con salto de bloques defectuosos), nunca escritura en bruto.
* Los scripts de instalación borran discos: deben pedir confirmación explícita (`BORRAR`) y comprobar
  el tamaño de los discos antes de actuar. No quites esas comprobaciones.
* No uses la vulnerabilidad CVE-2024-3273 del firmware de D-Link para nada.
* Distingue lo **probado en el equipo** de lo **no probado** y dilo en la documentación y en los commits.

## Qué no se sube al repositorio

* Binarios compilados (`uImage`, `uInitrd`, `.dtb`, el `.tar` de Debian): van en *releases* con su código fuente.
* Copias de la flash, firmware o binarios de D-Link.
* Contraseñas, hashes de contraseñas, claves SSH, claves de Tailscale, IP o MAC reales del usuario.

## Estilo

* Documentación, comentarios y mensajes de los scripts **en español**, evitando anglicismos cuando hay
  palabra española (núcleo, arranque, consola serie, memoria USB…).
* Cabecera `SPDX-License-Identifier: GPL-2.0-or-later` en scripts y código; el árbol de dispositivos
  usa `(GPL-2.0+ OR MIT)`.
* Scripts con `set -e`, mensajes de paso claros y fallos que expliquen qué hacer.
* Commits pequeños, con mensaje en español que diga qué cambia y por qué.

## Pendiente (por si quieres ayudar)

* Alimentación del USB 3.0 delantero (Etron EJ168, queda en D3cold): localizar el GPIO.
* LED (GPIO 50, 51, 57–59) y botón de encendido (aviso del microcontrolador por `ttyS1`).
* Reducir el initramfs de Debian.
* Ver el protocolo del microcontrolador en `docs/microcontrolador.md` (tramas `FA` + 5 bytes + `FB`).
