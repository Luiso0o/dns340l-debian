#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Genera uInitrd: arranque desde RAID + modo rescate (BusyBox, mdadm y mke2fs estáticos).
# Requisitos: git gcc-arm-linux-gnueabi make autoconf u-boot-tools cpio fakeroot
# Uso: ./compilar-initrd.sh [carpeta_de_trabajo]
set -euo pipefail

AQUI="$(cd "$(dirname "$0")" && pwd)"
TRABAJO="$(mkdir -p "${1:-$AQUI/../build}" && cd "${1:-$AQUI/../build}" && pwd)"
LIMITE=$((0x300000))   # U-Boot lee 3 MiB de la partición mtd2
export CROSS=arm-linux-gnueabi-

mkdir -p "$TRABAJO"; cd "$TRABAJO"

# --- BusyBox 1.36.1 estático
[ -d busybox ] || git clone --depth 1 -b 1_36_1 https://github.com/mirror/busybox.git busybox
( cd busybox
  make ARCH=arm CROSS_COMPILE=$CROSS defconfig >/dev/null
  sed -i -e 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' -e 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
  (set +o pipefail; yes "" | make ARCH=arm CROSS_COMPILE=$CROSS oldconfig >/dev/null)
  make -j"$(nproc)" ARCH=arm CROSS_COMPILE=$CROSS )

# --- mdadm estático
[ -d mdadm ] || git clone --depth 1 https://github.com/md-raid-utilities/mdadm.git mdadm
( cd mdadm && make -j"$(nproc)" CC=${CROSS}gcc CXFLAGS="-Os -DNO_LIBUDEV" LDFLAGS="-static" CWFLAGS="-Wall" mdadm && ${CROSS}strip mdadm )

# --- mke2fs estático (e2fsprogs 1.47.2)
[ -d e2fsprogs ] || git clone --depth 1 -b v1.47.2 https://github.com/tytso/e2fsprogs.git e2fsprogs
( cd e2fsprogs && mkdir -p b && cd b
  [ -f Makefile ] || ../configure --host=arm-linux-gnueabi --disable-nls --disable-fuse2fs --disable-uuidd \
	--disable-e2initrd-helper --without-libarchive --disable-defrag LDFLAGS=-static CFLAGS=-Os
  make -j"$(nproc)" libs && make -C misc mke2fs && ${CROSS}strip misc/mke2fs )

# --- Sistema de ficheros del initrd
RAIZ="$TRABAJO/initrd-raiz"
rm -rf "$RAIZ"
mkdir -p "$RAIZ"/{bin,sbin,usr/bin,usr/sbin,proc,sys,dev,tmp,run,mnt/usb,newroot,etc,root,var/log,www/cgi-bin}
( cd busybox && make ARCH=arm CROSS_COMPILE=$CROSS CONFIG_PREFIX="$RAIZ" install >/dev/null )
rm -f "$RAIZ/sbin/mdadm" "$RAIZ/sbin/mke2fs" "$RAIZ/sbin/mkfs.ext4"   # BusyBox instala enlaces con esos nombres
cp mdadm/mdadm "$RAIZ/sbin/"
cp e2fsprogs/b/misc/mke2fs "$RAIZ/sbin/"; ln -sf mke2fs "$RAIZ/sbin/mkfs.ext4"
install -m 755 "$AQUI/init" "$RAIZ/init"
install -m 755 "$AQUI/rescate.sh" "$RAIZ/rescate.sh"
install -m 755 "$AQUI/udhcpc.script" "$RAIZ/etc/udhcpc.script"
install -m 644 "$AQUI/www/index.html" "$RAIZ/www/index.html"
install -m 755 "$AQUI/www/cgi-bin/apagar" "$RAIZ/www/cgi-bin/apagar"
echo 'root::0:0:root:/root:/bin/sh' > "$RAIZ/etc/passwd"
echo 'root:x:0:' > "$RAIZ/etc/group"

# cpio con nodos de dispositivo (fakeroot evita necesitar root)
fakeroot sh -c "
	mknod -m 600 '$RAIZ/dev/console' c 5 1
	mknod -m 666 '$RAIZ/dev/null' c 1 3
	chown -R 0:0 '$RAIZ'
	cd '$RAIZ' && find . | sort | cpio -o -H newc --quiet" | gzip -9 > initrd.cpio.gz

mkimage -A arm -O linux -T ramdisk -C gzip -a 0x00e00000 -e 0x00e00000 -n Ramdisk -d initrd.cpio.gz uInitrd

TAM=$(stat -c %s uInitrd)
echo "uInitrd: $TAM bytes (límite $LIMITE)"
[ "$TAM" -le "$LIMITE" ] || { echo "ERROR: uInitrd supera 3 MiB"; exit 1; }
md5sum uInitrd
