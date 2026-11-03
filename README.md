# Debian 13 en el D-Link ShareCenter DNS-340L

Cómo sustituir el firmware de fábrica (abandonado desde 2018 y con la vulnerabilidad crítica
[CVE-2024-3273](https://nvd.nist.gov/vuln/detail/CVE-2024-3273) sin corregir) por **Debian 13 actual**,
con **Linux 6.12 LTS**, **RAID por software (`mdadm`)** y **SSH**.

> ⚠️ **Aviso.** Este proyecto se ofrece **TAL CUAL, SIN GARANTÍA DE NINGÚN TIPO**.
> Modificar la memoria flash puede dejar el equipo inservible y **la instalación borra por completo los discos**.
> Úsalo bajo tu propia responsabilidad. No está afiliado ni respaldado por D-Link.
> "D-Link" y "ShareCenter" son marcas de sus respectivos propietarios.

## Estado

| Componente | Estado |
|---|---|
| Marvell Armada 370 (1,2 GHz), 512 MiB | ✅ Linux 6.12 arranca desde la flash con el U-Boot original |
| 4 bahías SATA (Marvell 88SE9215, 6 Gbps) | ✅ |
| Red: 2 × gigabit (PHY Marvell 88E1510) | ✅ MAC fija definida en el árbol de dispositivos |
| USB 2.0 (los dos puertos traseros) | ✅ |
| Ventilador, encendido y apagado (microcontrolador Weltrend) | ✅ protocolo documentado, servicio para Debian |
| Temperatura de la CPU | ✅ |
| USB 3.0 delantero (Etron EJ168) | ✅ 5 Gbps con el núcleo de Debian (arrancado con kexec) |
| LED | ✅ encendido blanco/naranja en `/sys/class/leds/` (`white:power`, `amber:power`); los de las bahías los lleva la controladora SATA |
| Apagado y reinicio | ✅ `poweroff` y `reboot` pasan por el microcontrolador |
| Botones | 🟡 reset y copia USB llegan a Linux; el de encendido solo enciende (no avisa a Linux) |
| Arranque de Debian desde el RAID con `kexec` (núcleo v5 + arranque v6) | ✅ probado en el equipo 2 (3-11-2026): enciende y arranca Debian 13 solo |
| Cockpit (panel web, puerto 9090) y Tailscale | ✅ probados en el equipo 2 |
| Los dos equipos | ✅ 3-11-2026: equipo 2 instalado de cero; equipo 1 recuperado por la consola serie y reinstalado con `SOLO_SISTEMA=1` (conserva el RAID de datos) |
| Actualización del núcleo de Debian con `apt` | ✅ probada: 6.12.107 → 6.12.115, preparada sola por `zz-dns340l` y arrancada con kexec |

## Cómo queda el sistema

```
NAND (flash)                         Discos (2-4, GPT idéntica; aquí 4 × 4 TB)
├─ mtd0  U-Boot original (intacto)   ├─ part. 1  20 GiB ─┐ md0  RAID 1 ×4  ext4  "debian-raiz"  → Debian 13
├─ mtd1  Linux 6.12 (uImage ≤4 MiB)  ├─ part. 2   2 GiB ─┤ md1  RAID 1 ×4  swap
└─ mtd2  arranque (uInitrd ≤3 MiB)   └─ part. 3  resto  ─┘ md2  RAID 5     ext4  "datos" → /srv/datos
```

* **U-Boot no se modifica nunca.** Su orden de arranque de fábrica (que ignora variables guardadas,
  ver [docs/u-boot.md](docs/u-boot.md)) carga 4 MiB de `mtd1` y 3 MiB de `mtd2`: ahí van nuestro núcleo
  y nuestro arranque.
* El **arranque** (`initrd/init`) hace de "GRUB": ensambla los RAID, monta `LABEL=debian-raiz` y salta
  con **`kexec` al núcleo oficial de Debian** (`linux-image-armmp`) que hay en `/boot/dns340l/`. Debian
  funciona **siempre** con su núcleo, que se actualiza con `apt`, como en un PC, sin tocar la flash. El
  núcleo de la flash solo sirve para cargarlo y para el modo rescate.
* Si un núcleo de Debian no llega a arrancar (fichero `/boot/dns340l/intento` sin borrar), el siguiente
  encendido prueba el núcleo anterior (`*.old`); si tampoco, entra en modo rescate.
* En la consola serie muestra los discos, el estado del RAID, la raíz encontrada y, si algo falla, el
  motivo exacto. El registro queda en `/var/log/dns340l/` y en la memoria USB, si hay una pinchada.
* Si no puede arrancar Debian, o si hay una memoria USB FAT con un fichero `RESCATE`, entra en **modo rescate**
  (Telnet, web de diagnóstico, IP 192.168.1.250, `mdadm`, `mke2fs`, `kexec`).

## Próximos pasos

* El reinicio que hace el propio núcleo (p. ej. tras un *kernel panic* con `panic=`) sigue colgándose: solo `reboot` desde Debian pasa por el microcontrolador.
* Que Cockpit (`udisksd`) no bloquee el apagado mientras se reconstruye un RAID (de momento:
  `systemctl start poweroff.target`).
* Botón de encendido: con Debian no llega a Linux (ni GPIO ni microcontrolador) ni apaga; solo enciende.
  Botones de reset y copia USB: llegan como teclas (gpio-keys), sin función asignada.
* Modo rescate del arranque v6 (fichero `RESCATE` en la memoria USB) sin probar.
* Publicar `uImage` y `uInitrd` como *release*, con su código fuente.
* Discos de más de 16 TiB en total: ahora se limita el volumen de datos; se podría dividir en dos RAID.

## Guía rápida

1. **Copia de seguridad** de toda la flash desde el firmware de D-Link → [docs/instalacion.md](docs/instalacion.md#1-copia-de-seguridad)
2. **Compilar** núcleo y arranque (o usar los de la *release*):
   `kernel/compilar-nucleo.sh` y `initrd/compilar-initrd.sh`
3. **Grabar** `uImage` en `mtd1` y `uInitrd` en `mtd2` desde el firmware de D-Link (por SSH, como root) **o** desde U-Boot con la [consola serie](docs/consola-serie.md)
4. **Preparar Debian** en un PC Linux/WSL: `sudo USUARIO=tu_usuario bash debian/preparar-debian-dns340l.sh`
5. **Instalar** desde el modo rescate: `sh instalacion/instalar-nas.sh` (⚠️ borra los discos)
6. **Núcleo de Debian**: `sh debian/instalar-nucleo-debian.sh` (instala `linux-image-armmp` y lo deja listo para `kexec`)
7. Reiniciar y entrar por SSH.

Detalle completo en **[docs/instalacion.md](docs/instalacion.md)**.

## Documentación

| | |
|---|---|
| [docs/hardware.md](docs/hardware.md) | Componentes, PCIe, red, GPIO, MPP, particiones de la NAND |
| [docs/consola-serie.md](docs/consola-serie.md) | Conector de la consola serie y conexión del adaptador |
| [docs/microcontrolador.md](docs/microcontrolador.md) | Protocolo del Weltrend WT6701 (ventilador, encendido, reloj) |
| [docs/u-boot.md](docs/u-boot.md) | Lo descubierto en el U-Boot de D-Link |
| [docs/instalacion.md](docs/instalacion.md) | Instalación paso a paso |
| [docs/rescate.md](docs/rescate.md) | Modo rescate y recuperación |

## Estructura

```
kernel/        árbol de dispositivos, configuración de Linux 6.12 y script de compilación
initrd/        arranque (init), modo rescate y script de compilación (BusyBox, mdadm, mke2fs)
debian/        preparación de Debian 13 armhf (debootstrap), núcleo oficial con kexec (zz-dns340l)
instalacion/   instalar-nas.sh (particiona, crea RAID, instala; de 2 a 4 discos de cualquier tamaño)
herramientas/  borrar_env.c (borra solo la zona de variables de U-Boot; ver docs/u-boot.md)
docs/          documentación
```

## Créditos y referencias

* Árbol de dispositivos del **DNS-327L** en Linux (Andrew Andrianov), base de este trabajo.
* Proyecto **dns320l-daemon** y trabajos sobre el DNS-320L: mismo microcontrolador y protocolo.
* Hilos del grupo **Alt-F** y del foro de **Armbian** sobre el DNS-340L.

## Licencia

[GPL-2.0-or-later](LICENSE). El árbol de dispositivos se distribuye además bajo MIT, como el resto de
árboles de Linux (`GPL-2.0+ OR MIT`). Los binarios publicados incluyen Linux, BusyBox, mdadm y e2fsprogs
(GPL-2.0); su código fuente exacto se publica junto a cada *release*.
