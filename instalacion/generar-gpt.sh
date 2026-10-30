#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Genera las tablas GPT (principal y de respaldo) para los 4 discos, sin tocar ningún disco real.
# Requisitos: gdisk (sgdisk). Uso: ./generar-gpt.sh [SECTORES]   (por defecto, WD40EFRX: 7814037168)
#
# Esquema de cada disco:
#   1: 20 GiB  Linux RAID  "sistema" -> md0, RAID 1 de 4 discos, ext4 LABEL=debian-raiz
#   2:  2 GiB  Linux RAID  "swap"    -> md1, RAID 1 de 4 discos, swap LABEL=swap
#   3: resto - 100 MiB  Linux RAID  "datos" -> md2, RAID 5, ext4 LABEL=datos
set -euo pipefail
N=${1:-7814037168}
for n in 1 2 3 4; do
	rm -f disco.img; truncate -s $((N*512)) disco.img
	sgdisk -Z disco.img >/dev/null
	sgdisk -a 2048 \
		-n 1:2048:+20G -t 1:FD00 -c 1:sistema \
		-n 2:0:+2G     -t 2:FD00 -c 2:swap \
		-n 3:0:-100M   -t 3:FD00 -c 3:datos disco.img >/dev/null
	dd if=disco.img of=gpt_disco${n}_inicio.bin bs=512 count=34 status=none
	dd if=disco.img of=gpt_disco${n}_final.bin  bs=512 skip=$((N-33)) count=33 status=none
done
sgdisk -p disco.img | tail -4
rm -f disco.img
md5sum gpt_disco*.bin
