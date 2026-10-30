#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# MODO RESCATE del DNS-340L. Lo lanza /init si no encuentra Debian en el RAID o si se fuerza.
# - No escribe en la NAND ni monta los discos por sí mismo
# - Señales: ventilador al MÁXIMO = rescate arrancado; a MEDIA = la red tiene IP por DHCP
# - IP de reserva 192.168.1.250 (eth0) y 192.168.1.251 (eth1): cámbialas abajo si tu red es otra
# - Web de diagnóstico (http://IP/estado.txt), Telnet SIN contraseña (solo para red local)
# - Copia el diagnóstico en la primera memoria USB FAT que encuentre (dns340l-log.txt)

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mkdir -p /dev/pts && mount -t devpts devpts /dev/pts 2>/dev/null
mount -t tmpfs tmpfs /tmp 2>/dev/null
echo /bin/mdev > /proc/sys/kernel/hotplug 2>/dev/null
mdev -s

LOG=/tmp/arranque.txt
log() { echo "[$(cut -d' ' -f1 /proc/uptime)] $*" | tee -a $LOG > /dev/console; }

# ---------- Microcontrolador (ttyS1, protocolo del DNS-320L) ----------
mcu() {
	# $1 = bytes en octal entre FA y FB
	[ -c /dev/ttyS1 ] || return 1
	printf "\372$1\373" > /dev/ttyS1
}
if [ -c /dev/ttyS1 ]; then
	stty -F /dev/ttyS1 115200 cs8 -cstopb -parenb raw -echo 2>/dev/null
	mcu '\003\001\000\000\000'   # DeviceReady
	sleep 1
	mcu '\002\000\002\000\000'   # FanFull  -> señal "estoy vivo"
	log "MCU: DeviceReady y ventilador al maximo enviados"
else
	log "MCU: no existe /dev/ttyS1"
fi

log "Nucleo: $(uname -r)  cmdline: $(cat /proc/cmdline)"

# ---------- Red ----------
arg() { tr ' ' '\n' < /proc/cmdline | sed -n "s/^$1=//p" | head -n1; }
MAC0=$(arg ethaddr); MAC1=$(arg eth1addr)

sleep 3
for IF in eth0 eth1; do
	[ -e /sys/class/net/$IF ] || { log "Red: $IF no existe"; continue; }
	[ $IF = eth0 ] && [ -n "$MAC0" ] && ip link set $IF address $MAC0
	[ $IF = eth1 ] && [ -n "$MAC1" ] && ip link set $IF address $MAC1
	ip link set $IF up
done
ip link set lo up
ip addr add 127.0.0.1/8 dev lo 2>/dev/null
# IP fija de reserva (además de DHCP)
[ -e /sys/class/net/eth0 ] && ip addr add 192.168.1.250/24 dev eth0
[ -e /sys/class/net/eth1 ] && ip addr add 192.168.1.251/24 dev eth1
for IF in eth0 eth1; do
	[ -e /sys/class/net/$IF ] && udhcpc -b -q -t 10 -T 3 -i $IF -s /etc/udhcpc.script >/dev/null 2>&1 &
done

# ---------- Servicios de diagnóstico ----------
httpd -p 80 -h /www
telnetd -l /bin/sh

# ---------- Memoria USB: la primera con formato FAT ----------
USB=""
buscar_usb() {
	for d in /dev/sd[a-z]1 /dev/sd[a-z]; do
		[ -b "$d" ] || continue
		# Solo memorias FAT: los discos (ext4/RAID) no montan como vfat
		mount -t vfat -o rw "$d" /mnt/usb 2>/dev/null || continue
		USB=$d && return 0
	done
	return 1
}

diagnostico() {
	echo "===== DNS-340L prueba  $(date)  uptime $(cut -d' ' -f1 /proc/uptime) s"
	echo "--- cmdline";      cat /proc/cmdline
	echo "--- arranque";     cat $LOG
	echo "--- ip addr";      ip addr
	echo "--- PHY MDIO";     for p in /sys/bus/mdio_bus/devices/*; do [ -e "$p/phy_id" ] && echo "$(basename $p) id=$(cat $p/phy_id)"; done
	echo "--- lspci";        lspci
	echo "--- lsusb";        lsusb
	echo "--- particiones";  cat /proc/partitions
	echo "--- interrupts";   cat /proc/interrupts
	echo "--- iomem";        cat /proc/iomem
	echo "--- gpio";         ls /sys/class/gpio 2>/dev/null
	echo "--- dmesg";        dmesg
}

# Bucle: actualiza la web y el registro en USB cada 15 s durante 15 min
FAN_MEDIA=0
i=0
while true; do
	diagnostico > /www/estado.txt 2>&1
	if [ $FAN_MEDIA = 0 ] && ip -4 addr | grep -v 127.0.0.1 | grep -v '192.168.1.25[01]' | grep -q 'inet '; then
		mcu '\002\000\001\000\000'   # FanHalf -> señal "tengo IP"
		log "Red: IP obtenida por DHCP, ventilador a media"
		FAN_MEDIA=1
	fi
	if [ -z "$USB" ]; then buscar_usb && log "USB: registro en $USB"; fi
	if [ -n "$USB" ] && [ $i -lt 60 ]; then
		cp /www/estado.txt /mnt/usb/dns340l-log.txt
		sync
	fi
	i=$((i+1))
	sleep 15
done
