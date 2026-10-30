#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Instalación de Debian 13 en el DNS-340L desde el MODO RESCATE.
# BORRA LOS 4 DISCOS DE 4 TB. Uso (por telnet, desde la carpeta de la memoria USB):
#   sh instalar-nas.sh
# Ficheros necesarios junto a este script:
#   dns340l-debian.tar.gz, gpt_disco[1-4]_inicio.bin, gpt_disco[1-4]_final.bin
set -e
cd "$(dirname "$0")"
# Herramientas (mdadm, mke2fs) junto al script, por si el sistema no las trae
export PATH="$(pwd):$PATH"
mkdir -p /run/mdadm
SECTORES=7814037168          # tamaño exacto de los WD40EFRX

paso() { echo; echo "=== $*"; }
fallo() { echo; echo "*** ERROR: $* ***"; echo "No se ha completado la instalación."; exit 1; }

paso "Comprobaciones previas"
command -v mdadm  >/dev/null || fallo "no encuentro mdadm (cópialo junto al script)"
command -v mke2fs >/dev/null || fallo "no encuentro mke2fs (cópialo junto al script)"
mdadm --version
for f in dns340l-debian.tar.gz; do [ -f "$f" ] || fallo "falta el fichero $f"; done
for n in 1 2 3 4; do
	[ -f gpt_disco${n}_inicio.bin ] && [ -f gpt_disco${n}_final.bin ] || fallo "faltan los ficheros gpt_disco${n}_*.bin"
done

# Localizar los 4 discos por su tamaño (así nunca se confunde con la memoria USB)
DISCOS=""
for b in /sys/block/sd*; do
	[ "$(cat $b/size)" = "$SECTORES" ] && DISCOS="$DISCOS ${b##*/}"
done
set -- $DISCOS
[ $# = 4 ] || fallo "se esperaban 4 discos de $SECTORES sectores y hay $# ($DISCOS)"
for d in $DISCOS; do
	grep -q "^/dev/$d" /proc/mounts && fallo "/dev/$d está montado"
	echo "/dev/$d: $(cat /sys/block/$d/device/model 2>/dev/null)  OK"
done

echo
echo "Se van a BORRAR por completo estos discos:$DISCOS"
printf "Escribe BORRAR para continuar: "
read r
[ "$r" = BORRAR ] || fallo "cancelado por el usuario"

paso "Deteniendo RAID antiguos y borrando sus firmas"
mdadm --stop --scan 2>/dev/null || true
for d in $DISCOS; do
	for p in /dev/${d}[0-9]*; do
		[ -b "$p" ] || continue
		mdadm --zero-superblock "$p" 2>/dev/null || true
		dd if=/dev/zero of="$p" bs=1M count=16 2>/dev/null || true
	done
	dd if=/dev/zero of=/dev/$d bs=1M count=16 2>/dev/null
	dd if=/dev/zero of=/dev/$d bs=512 seek=$((SECTORES-2048)) count=2048 2>/dev/null
done
sync

paso "Escribiendo tablas de particiones GPT"
n=0
for d in $DISCOS; do
	n=$((n+1))
	dd if=gpt_disco${n}_inicio.bin of=/dev/$d bs=512 conv=fsync 2>/dev/null
	dd if=gpt_disco${n}_final.bin of=/dev/$d bs=512 seek=$((SECTORES-33)) conv=fsync 2>/dev/null
	blockdev --rereadpt /dev/$d
done
sleep 2; mdev -s
P1=""; P2=""; P3=""
for d in $DISCOS; do
	for k in 1 2 3; do [ -b /dev/$d$k ] || fallo "no aparece /dev/$d$k tras particionar"; done
	P1="$P1 /dev/${d}1"; P2="$P2 /dev/${d}2"; P3="$P3 /dev/${d}3"
	echo "/dev/$d: particiones 1-3 OK"
done

paso "Limpiando el principio de las particiones nuevas"
for p in $P1 $P2 $P3; do
	mdadm --zero-superblock "$p" 2>/dev/null || true
	dd if=/dev/zero of="$p" bs=1M count=16 2>/dev/null
done
sync

paso "Creando RAID 1 del sistema (md0), RAID 1 de intercambio (md1) y RAID 5 de datos (md2)"
mdadm --create /dev/md0 --run --level=1 --raid-devices=4 --metadata=1.2 --name=sistema $P1
mdadm --create /dev/md1 --run --level=1 --raid-devices=4 --metadata=1.2 --name=swap    $P2
mdadm --create /dev/md2 --run --level=5 --raid-devices=4 --metadata=1.2 --name=datos --chunk=512 --bitmap=internal $P3
sleep 2; mdev -s
cat /proc/mdstat

paso "Formateando"
mke2fs -F -t ext4 -L debian-raiz /dev/md0
mkswap -L swap /dev/md1
mke2fs -F -t ext4 -L datos -m 0 -E lazy_itable_init=1,lazy_journal_init=1 /dev/md2

paso "Instalando Debian en md0 (tarda unos minutos)"
mkdir -p /newroot
mount -t ext4 /dev/md0 /newroot
tar -xzpf dns340l-debian.tar.gz -C /newroot
[ -e /newroot/sbin/init ] || [ -L /newroot/sbin/init ] || fallo "no se ha extraído bien el sistema"
sync
umount /newroot

paso "INSTALACIÓN TERMINADA"
cat /proc/mdstat
echo
echo "El RAID 5 de datos se sincroniza en segundo plano (puede tardar 10-15 horas)."
echo "Siguiente paso: borra el fichero RESCATE de la memoria USB y reinicia con: reboot"
