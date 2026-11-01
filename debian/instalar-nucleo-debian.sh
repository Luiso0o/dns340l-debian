#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Instala el núcleo oficial de Debian (linux-image-armmp) en el sistema del RAID y lo prepara
# en /boot/dns340l/ para arrancarlo con kexec. Se ejecuta desde el MODO RESCATE (o el sistema
# de prueba) por Telnet, en la carpeta de la memoria USB que contiene:
#   instalar-nucleo-debian.sh, zz-dns340l, dns340l-arranque-ok.service, armada-370-dlink-dns340l.dtb
#   (y mdadm si el sistema no lo trae)
# Necesita red con salida a Internet (deb.debian.org).
set -e
cd "$(dirname "$0")"
export PATH="$(pwd):$PATH"
R=/newroot

paso() { echo; echo "=== $*"; }
fallo() { echo; echo "*** ERROR: $* ***"; exit 1; }

for f in zz-dns340l armada-370-dlink-dns340l.dtb dns340l-arranque-ok.service; do [ -f "$f" ] || fallo "falta $f"; done

paso "Hora del sistema (apt la necesita correcta)"
ntpd -q -n -p 0.debian.pool.ntp.org 2>/dev/null || ntpd -q -n -p pool.ntp.org 2>/dev/null || true
date
[ "$(date +%Y)" -ge 2026 ] || fallo "la hora es incorrecta; ponla a mano: date -s 'AAAA-MM-DD hh:mm'"

paso "Montando el sistema Debian"
mkdir -p /run/mdadm $R
if ! grep -q " $R " /proc/mounts; then
	if ! findfs LABEL=debian-raiz >/dev/null 2>&1; then
		echo 'DEVICE partitions' > /run/mdadm.conf
		mdadm --assemble --scan --config=/run/mdadm.conf || true
		sleep 2; mdev -s
	fi
	ROOT=$(findfs LABEL=debian-raiz) || fallo "no encuentro LABEL=debian-raiz"
	mount -t ext4 "$ROOT" $R
fi
[ -x $R/usr/bin/apt-get ] || fallo "$R no parece un sistema Debian"
for d in dev proc sys; do grep -q " $R/$d " /proc/mounts || mount -o bind /$d $R/$d; done
mkdir -p $R/dev/pts; grep -q " $R/dev/pts " /proc/mounts || mount -t devpts devpts $R/dev/pts

paso "DNS temporal para el chroot"
mv $R/etc/resolv.conf $R/etc/resolv.conf.dns340l
grep nameserver /etc/resolv.conf > $R/etc/resolv.conf 2>/dev/null || echo "nameserver 192.168.1.1" > $R/etc/resolv.conf
restaurar() {
	rm -f $R/etc/resolv.conf
	mv $R/etc/resolv.conf.dns340l $R/etc/resolv.conf
	for d in dev/pts dev proc sys; do umount $R/$d 2>/dev/null || true; done
}
trap restaurar EXIT

paso "Instalando el hook y el árbol de dispositivos"
mkdir -p $R/etc/dns340l $R/etc/kernel/postinst.d $R/etc/initramfs/post-update.d
cp armada-370-dlink-dns340l.dtb $R/etc/dns340l/
install -m 755 zz-dns340l $R/etc/kernel/postinst.d/zz-dns340l
install -m 755 zz-dns340l $R/etc/initramfs/post-update.d/zz-dns340l
install -m 644 dns340l-arranque-ok.service $R/etc/systemd/system/dns340l-arranque-ok.service
chroot $R systemctl enable dns340l-arranque-ok.service

paso "Definiendo los RAID en mdadm.conf"
chroot $R /bin/sh -c '/usr/share/mdadm/mkconf > /etc/mdadm/mdadm.conf.nuevo && mv /etc/mdadm/mdadm.conf.nuevo /etc/mdadm/mdadm.conf'
cat $R/etc/mdadm/mdadm.conf

paso "Descargando e instalando linux-image-armmp (tarda varios minutos)"
chroot $R /usr/bin/env DEBIAN_FRONTEND=noninteractive /bin/sh -c \
	'apt-get update && apt-get install -y --no-install-recommends linux-image-armmp initramfs-tools'
chroot $R /etc/kernel/postinst.d/zz-dns340l

paso "Resultado"
ls -l $R/boot/dns340l/
cat $R/boot/dns340l/version
sync
echo
echo "Listo. El arranque de la flash (v4) cargará este núcleo con kexec."
