#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Compila el núcleo Linux para el D-Link DNS-340L y genera uImage (núcleo + árbol de dispositivos).
# Requisitos (Debian/Ubuntu): git gcc-arm-linux-gnueabi make bc bison flex libssl-dev u-boot-tools device-tree-compiler
# Uso: ./compilar-nucleo.sh [carpeta_de_trabajo]
set -euo pipefail

VERSION=v6.12
AQUI="$(cd "$(dirname "$0")" && pwd)"
TRABAJO="$(mkdir -p "${1:-$AQUI/../build}" && cd "${1:-$AQUI/../build}" && pwd)"
LIMITE=$((0x400000))   # U-Boot lee 4 MiB de la partición mtd1

mkdir -p "$TRABAJO"; cd "$TRABAJO"
[ -d linux ] || git clone --depth 1 -b "$VERSION" https://github.com/torvalds/linux.git linux

cp "$AQUI/armada-370-dlink-dns340l.dtsi" "$AQUI/armada-370-dlink-dns340l-f1.dts" linux/arch/arm/boot/dts/marvell/
cp "$AQUI/config-6.12-dns340l" linux/.config

cd linux
export ARCH=arm CROSS_COMPILE=arm-linux-gnueabi-
make olddefconfig
make -j"$(nproc)" zImage marvell/armada-370-dlink-dns340l-f1.dtb

# El U-Boot de 2011 no pasa árbol de dispositivos: se añade al final del zImage
cat arch/arm/boot/zImage arch/arm/boot/dts/marvell/armada-370-dlink-dns340l-f1.dtb > "$TRABAJO/zImage-dtb"
mkimage -A arm -O linux -T kernel -C none -a 0x00008000 -e 0x00008000 \
	-n "DNS-340L Linux $(make -s kernelversion)" -d "$TRABAJO/zImage-dtb" "$TRABAJO/uImage"
cd "$TRABAJO"

TAM=$(stat -c %s uImage)
echo "uImage: $TAM bytes (límite $LIMITE)"
[ "$TAM" -le "$LIMITE" ] || { echo "ERROR: uImage supera 4 MiB y U-Boot no lo leerá entero"; exit 1; }
cp linux/arch/arm/boot/dts/marvell/armada-370-dlink-dns340l-f1.dtb armada-370-dlink-dns340l.dtb
md5sum uImage armada-370-dlink-dns340l.dtb
