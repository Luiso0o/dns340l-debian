#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""
Crea, a partir de TU copia de mtd0 (U-Boot de D-Link, firmware 1.08b01), una imagen de U-Boot
con 5 segundos de espera para arrancarla POR LA CONSOLA SERIE con kwboot. No se graba en la flash:
se ejecuta en memoria y sirve para llegar a "Marvell>>" cuando el U-Boot de la flash tiene la
espera a 0 (variables de U-Boot borradas -> "bad CRC, using default environment").

Uso:  python3 uboot-con-espera.py mtd0.bin u-boot-espera5.kwb
      sudo kwboot -t -p -B 115200 -b u-boot-espera5.kwb /dev/ttyUSB0    (y encender el NAS)
      Durante la cuenta atrás, pulsar la tecla 1 (solo esa tecla interrumpe el arranque).
"""
import struct, sys

ORIGEN = 0x11000          # inicio de U-Boot dentro de la imagen kwb (tras la cabecera y el entrenamiento DDR)
PARCHE = 0x3a4b8          # main_loop: "mov r4, r0" (bootdelay leído de la variable) -> "mov r4, #5"

d = bytearray(open(sys.argv[1], 'rb').read())
if d[0] != 0x8B or d[8] != 1:
    sys.exit("No parece una copia de mtd0 del DNS-340L (cabecera kwb v1 de NAND)")
tam = struct.unpack_from('<I', d, 4)[0]
if struct.unpack_from('<I', d, 0x0C)[0] != ORIGEN:
    sys.exit("Disposición distinta de la esperada: no se modifica nada")
o = ORIGEN + PARCHE
if d[o:o + 4] != bytes.fromhex('0040a0e1'):
    sys.exit("La instrucción no coincide (¿otra versión de U-Boot?): no se modifica nada")
d[o:o + 4] = bytes.fromhex('0540a0e3')
n = (tam - 4) // 4
struct.pack_into('<I', d, ORIGEN + tam - 4, sum(struct.unpack_from('<%dI' % n, d, ORIGEN)) & 0xFFFFFFFF)
open(sys.argv[2], 'wb').write(bytes(d[:ORIGEN + tam]))
print("Creado", sys.argv[2])
