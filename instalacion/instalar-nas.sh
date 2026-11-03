#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Instalación de Debian 13 en el DNS-340L desde el MODO RESCATE.
# BORRA LOS DISCOS SATA DEL NAS. Uso (por Telnet o consola serie, desde la carpeta de la memoria USB):
#   sh instalar-nas.sh
# Ficheros necesarios junto a este script:
#   dns340l-debian.tar.gz y sfdisk (estático, lo genera initrd/compilar-initrd.sh)
#
# Acepta de 2 a 4 discos de cualquier tamaño. Todos reciben la misma tabla GPT, calculada sobre el
# disco más pequeño:
#   1: 20 GiB  Linux RAID "sistema" -> md0  RAID 1 (todos los discos)  ext4 LABEL=debian-raiz
#   2:  2 GiB  Linux RAID "swap"    -> md1  RAID 1 (todos los discos)  swap LABEL=swap
#   3: resto   Linux RAID "datos"   -> md2  RAID 5 (3-4 discos) o RAID 1 (2 discos)  ext4 LABEL=datos
# Se dejan 100 MiB libres al final de cada disco para poder sustituir uno por otro algo más pequeño.
# Con el núcleo de 32 bits, un volumen no puede pasar de 16 TiB: si md2 lo superaría, se reduce la
# partición 3 (se avisa antes de borrar nada).
set -e
cd "$(dirname "$0")"
# Herramientas junto al script, por si el sistema no las trae
export PATH="$(pwd):$PATH"
mkdir -p /run/mdadm

TIPO=A19D880F-05FC-4D3B-A006-743F0F84911E   # Linux RAID
MIB=2048                                     # sectores de 512 bytes por MiB
GIB=$((1024*MIB))
INICIO=$MIB                                  # primera partición a 1 MiB
P1=$((20*GIB)); P2=$((2*GIB))
RESERVA=$((100*MIB))                         # libre al final de cada disco
LIMITE=$(( (16*1024 - 1) * GIB ))            # 16 TiB menos 1 GiB, en sectores

paso() { echo; echo "=== $*"; }
fallo() { echo; echo "*** ERROR: $* ***"; echo "No se ha completado la instalación."; exit 1; }
gib() { echo "$(( $1 / GIB )) GiB"; }

paso "Comprobaciones previas"
command -v mdadm  >/dev/null || fallo "no encuentro mdadm (cópialo junto al script)"
command -v mke2fs >/dev/null || fallo "no encuentro mke2fs (cópialo junto al script)"
if [ -f sfdisk ]; then chmod +x sfdisk 2>/dev/null || true; fi
command -v sfdisk >/dev/null || fallo "no encuentro sfdisk (cópialo junto al script)"
[ -f dns340l-debian.tar.gz ] || fallo "falta el fichero dns340l-debian.tar.gz"

# Discos SATA de las bahías (nunca la memoria USB: se distinguen por la ruta en /sys)
DISCOS=""; N=0; MIN=0
for b in /sys/block/sd*; do
	[ -e "$b" ] || continue
	readlink -f "$b" | grep -q /ata || continue
	d=${b##*/}; s=$(cat $b/size)
	DISCOS="$DISCOS $d"; N=$((N+1))
	[ $MIN = 0 ] || [ "$s" -lt $MIN ] && MIN=$s
done
[ $N -ge 2 ] || fallo "hacen falta al menos 2 discos SATA y hay $N"

for d in $DISCOS; do
	grep -q "^/dev/$d" /proc/mounts && fallo "/dev/$d (o una de sus particiones) está montado"
	grep -q "^/dev/$d" /proc/swaps  && fallo "/dev/$d tiene una partición de intercambio activa"
done

# RAID activos que usan estos discos: no pueden estar montados ni en uso como intercambio
RAIDS=""
for m in /sys/block/md*; do
	[ -e "$m" ] || continue
	md=${m##*/}
	for s in $m/slaves/*; do
		[ -e "$s" ] || continue
		for d in $DISCOS; do
			case "${s##*/}" in $d*) RAIDS="$RAIDS $md"; break 2;; esac
		done
	done
done
for md in $RAIDS; do
	grep -q "^/dev/$md " /proc/mounts && fallo "/dev/$md (RAID con estos discos) está montado en $(grep "^/dev/$md " /proc/mounts | cut -d' ' -f2). Desmóntalo antes: umount /dev/$md"
	grep -q "^/dev/$md " /proc/swaps  && fallo "/dev/$md (RAID con estos discos) se usa como intercambio. Desactívalo: swapoff /dev/$md"
done

# Tamaño de la partición de datos (igual en todos los discos), alineada a 1 MiB
P3=$(( (MIN - INICIO - P1 - P2 - RESERVA - 33) / MIB * MIB ))
[ $P3 -ge $GIB ] || fallo "el disco más pequeño ($(gib $MIN)) es demasiado pequeño"
if [ $N -ge 3 ]; then NIVEL=5; DATOS=$(( P3 * (N-1) )); else NIVEL=1; DATOS=$P3; fi
AVISO=""
if [ $DATOS -gt $LIMITE ]; then
	if [ $NIVEL = 5 ]; then P3N=$(( LIMITE / (N-1) / MIB * MIB )); else P3N=$(( LIMITE / MIB * MIB )); fi
	ANTES=$DATOS; P3=$P3N
	if [ $NIVEL = 5 ]; then DATOS=$(( P3 * (N-1) )); else DATOS=$P3; fi
	AVISO="El volumen de datos se limita a 16 TiB (núcleo de 32 bits): de $(gib $ANTES) se usarán $(gib $DATOS)."
fi

echo
echo "Discos encontrados ($N):"
for d in $DISCOS; do
	echo "   /dev/$d  $(gib $(cat /sys/block/$d/size))  $(cat /sys/block/$d/device/model 2>/dev/null)"
done
for md in $RAIDS; do echo "   (RAID activo con estos discos: /dev/$md, se detendrá)"; done
echo
echo "Esquema en cada disco: sistema 20 GiB, intercambio 2 GiB, datos $(gib $P3)"
echo "   md0 sistema       RAID 1 de $N discos"
echo "   md1 intercambio   RAID 1 de $N discos"
echo "   md2 datos         RAID $NIVEL de $N discos: $(gib $DATOS) útiles"
[ -n "$AVISO" ] && echo "AVISO: $AVISO"
echo
echo "Se van a BORRAR por completo estos discos:$DISCOS"
printf "Escribe BORRAR para continuar: "
read r
[ "$r" = BORRAR ] || fallo "cancelado por el usuario"

paso "Deteniendo RAID antiguos y borrando sus firmas"
for md in $RAIDS; do
	mdadm --stop /dev/$md || fallo "no se puede detener /dev/$md; no se ha borrado nada"
done
for md in $RAIDS; do
	[ -e /sys/block/$md/md/array_state ] && [ "$(cat /sys/block/$md/md/array_state)" != clear ] && \
		fallo "/dev/$md sigue activo; no se ha borrado nada"
done
for d in $DISCOS; do
	S=$(cat /sys/block/$d/size)
	for p in /dev/${d}[0-9]*; do
		[ -b "$p" ] || continue
		mdadm --zero-superblock "$p" 2>/dev/null || true
		dd if=/dev/zero of="$p" bs=1M count=16 2>/dev/null || true
	done
	dd if=/dev/zero of=/dev/$d bs=1M count=16 2>/dev/null
	dd if=/dev/zero of=/dev/$d bs=512 seek=$((S-2048)) count=2048 2>/dev/null
done
sync

paso "Escribiendo tablas de particiones GPT"
cat > /tmp/tabla-gpt <<EOF
label: gpt
start=$INICIO, size=$P1, type=$TIPO, name=sistema
start=$((INICIO+P1)), size=$P2, type=$TIPO, name=swap
start=$((INICIO+P1+P2)), size=$P3, type=$TIPO, name=datos
EOF
cat /tmp/tabla-gpt
for d in $DISCOS; do
	sfdisk -q --wipe always /dev/$d < /tmp/tabla-gpt || fallo "sfdisk no ha podido particionar /dev/$d"
done
sleep 2; mdev -s
L1=""; L2=""; L3=""
for d in $DISCOS; do
	for k in 1 2 3; do [ -b /dev/$d$k ] || fallo "no aparece /dev/$d$k tras particionar"; done
	L1="$L1 /dev/${d}1"; L2="$L2 /dev/${d}2"; L3="$L3 /dev/${d}3"
	echo "/dev/$d: particiones 1-3 OK"
done

paso "Limpiando el principio de las particiones nuevas"
for p in $L1 $L2 $L3; do
	mdadm --zero-superblock "$p" 2>/dev/null || true
	dd if=/dev/zero of="$p" bs=1M count=16 2>/dev/null
done
sync

paso "Creando RAID 1 del sistema (md0), RAID 1 de intercambio (md1) y RAID $NIVEL de datos (md2)"
mdadm --create /dev/md0 --run --level=1 --raid-devices=$N --metadata=1.2 --name=sistema $L1
mdadm --create /dev/md1 --run --level=1 --raid-devices=$N --metadata=1.2 --name=swap    $L2
if [ $NIVEL = 5 ]; then
	mdadm --create /dev/md2 --run --level=5 --raid-devices=$N --metadata=1.2 --name=datos --chunk=512 --bitmap=internal $L3
else
	mdadm --create /dev/md2 --run --level=1 --raid-devices=$N --metadata=1.2 --name=datos --bitmap=internal $L3
fi
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

paso "Preparando el arranque de Debian para estos RAID"
# Sin las líneas ARRAY, el initramfs de Debian no ensambla el RAID del sistema y no arranca
# (probado en el DNS-340L, equipo 2). El .tar se genera en un PC sin discos, así que se añaden aquí.
mdadm --detail --scan | sed 's/ spares=[0-9]*//' >> /newroot/etc/mdadm/mdadm.conf
grep ARRAY /newroot/etc/mdadm/mdadm.conf
# Diagnóstico sin consola serie: el initramfs de Debian manda los mensajes del núcleo por la red
# (UDP 6666 a toda la red desde 192.168.1.250; se ven con Wireshark). Ver docs/kexec.md.
if ! grep -q '^netconsole' /newroot/etc/initramfs-tools/modules 2>/dev/null; then
	cat >> /newroot/etc/initramfs-tools/modules <<'EOF2'
# DNS-340L: mensajes del arranque por la red (diagnóstico)
mvmdio
marvell
mvneta
netconsole netconsole=6665@192.168.1.250/eth0,6666@255.255.255.255/ff:ff:ff:ff:ff:ff
EOF2
fi
if ls /newroot/boot/vmlinuz-* >/dev/null 2>&1; then
	for d in proc sys dev; do mount --bind /$d /newroot/$d; done
	chroot /newroot /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin update-initramfs -u -k all || \
		echo "AVISO: update-initramfs ha fallado; el arranque de Debian puede no encontrar el RAID"
	for d in dev sys proc; do umount /newroot/$d; done
else
	echo "AVISO: el sistema no trae núcleo de Debian (/boot/vmlinuz-*); no podrá arrancar con kexec"
fi
sync
umount /newroot

paso "INSTALACIÓN TERMINADA"
cat /proc/mdstat
echo
echo "El RAID de datos se sincroniza en segundo plano (con discos grandes puede tardar muchas horas)."
echo "Siguiente paso: borrar el fichero RESCATE de la memoria USB (si lo hay) y apagar y encender."
