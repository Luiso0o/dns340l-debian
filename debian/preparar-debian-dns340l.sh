#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Prepara un Debian 13 (trixie) armhf mínimo para el D-Link DNS-340L.
# Se ejecuta en Kali/Debian/Ubuntu (también en WSL) con:
#   sudo apt install -y debootstrap qemu-user-binfmt binfmt-support debian-archive-keyring curl
#   sudo USUARIO=tu_usuario bash preparar-debian-dns340l.sh
# Opcional: COCKPIT=0, TAILSCALE=0, NUCLEO=0. Para el núcleo de Debian, deja junto a este script
# zz-dns340l y armada-370-dlink-dns340l.dtb (lo genera kernel/compilar-nucleo.sh).
# Resultado: ~/dns340l-debian.tar.gz  (se copia a una memoria USB para el NAS)
set -euo pipefail

DEST=/var/tmp/dns340l-rootfs
MIRROR=http://deb.debian.org/debian
SALIDA="${SUDO_USER:+/home/$SUDO_USER}"; SALIDA="${SALIDA:-$HOME}/dns340l-debian.tar.gz"
USUARIO="${USUARIO:-admin}"   # cámbialo: sudo USUARIO=pepe bash preparar-debian-dns340l.sh
COCKPIT="${COCKPIT:-1}"       # panel web Cockpit (puerto 9090). COCKPIT=0 para no instalarlo
TAILSCALE="${TAILSCALE:-1}"   # VPN Tailscale. TAILSCALE=0 para no instalarlo
NUCLEO="${NUCLEO:-1}"         # núcleo oficial de Debian + hook kexec (necesita zz-dns340l y el .dtb al lado)
AQUI="$(cd "$(dirname "$0")" && pwd)"

[ "$(id -u)" = 0 ] || { echo "Ejecútalo con sudo"; exit 1; }
command -v debootstrap >/dev/null || { echo "Falta debootstrap"; exit 1; }

echo "== Activando la emulación ARM (qemu-user-static)"
update-binfmts --enable qemu-arm 2>/dev/null || service binfmt-support start 2>/dev/null || true
if ! [ -e /proc/sys/fs/binfmt_misc/qemu-arm ]; then
	mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
	update-binfmts --enable qemu-arm || true
fi
[ -e /proc/sys/fs/binfmt_misc/qemu-arm ] || { echo "ERROR: no se pudo activar qemu-arm en binfmt_misc"; exit 1; }

echo "== Descargando e instalando Debian 13 armhf en $DEST (tarda 10-20 min)"
rm -rf "$DEST"
debootstrap --arch=armhf --variant=minbase \
  --include=systemd,systemd-sysv,systemd-resolved,systemd-timesyncd,udev,dbus,openssh-server,mdadm,smartmontools,sudo,nano,less,iproute2,iputils-ping,ca-certificates,procps,e2fsprogs,gdisk,rsync,cron,logrotate,locales,tzdata,bash-completion,unattended-upgrades,apt-listchanges \
  trixie "$DEST" "$MIRROR"

echo "== Configurando"
echo dns340l > "$DEST/etc/hostname"
cat > "$DEST/etc/hosts" <<'EOF'
127.0.0.1	localhost
127.0.1.1	dns340l
::1		localhost ip6-localhost ip6-loopback
EOF

cat > "$DEST/etc/fstab" <<'EOF'
# Sistema: RAID 1 (md, 4 discos, partición 1)
LABEL=debian-raiz  /            ext4  errors=remount-ro,noatime  0 1
# Intercambio: RAID 1 (partición 2)
LABEL=swap         none         swap  sw                         0 0
# Datos: RAID 5 (partición 3)
LABEL=datos        /srv/datos   ext4  defaults,noatime,nofail    0 2
EOF
mkdir -p "$DEST/srv/datos"

cat > "$DEST/etc/apt/sources.list" <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free-firmware
EOF

# Red: DHCP en el primer puerto (MAC fija 02:d3:40:4c:00:01 en el árbol de dispositivos).
# Según la versión de systemd y del árbol de dispositivos, el puerto puede llamarse eth0 o end0: se aceptan los dos.
# ClientIdentifier=mac para que el router identifique al NAS por su MAC (reservas de IP).
mkdir -p "$DEST/etc/systemd/network"
cat > "$DEST/etc/systemd/network/10-lan.network" <<'EOF'
[Match]
Name=end0 eth0

[Network]
DHCP=yes

[DHCPv4]
ClientIdentifier=mac
EOF

# mdadm: los RAID los ensambla el arranque de la flash; aquí solo vigilancia
cat > "$DEST/etc/mdadm/mdadm.conf" <<'EOF'
DEVICE partitions
HOMEHOST <system>
MAILADDR root
EOF

# SSH: sin root, con contraseña de momento (pasar a claves más adelante)
mkdir -p "$DEST/etc/ssh/sshd_config.d"
cat > "$DEST/etc/ssh/sshd_config.d/10-dns340l.conf" <<'EOF'
PermitRootLogin no
PasswordAuthentication yes
EOF

# Idioma y zona horaria
sed -i 's/^# *es_ES.UTF-8/es_ES.UTF-8/' "$DEST/etc/locale.gen"
chroot "$DEST" locale-gen
echo 'LANG=es_ES.UTF-8' > "$DEST/etc/default/locale"
ln -sf /usr/share/zoneinfo/Europe/Madrid "$DEST/etc/localtime"
echo Europe/Madrid > "$DEST/etc/timezone"

# Ventilador (microcontrolador Weltrend en ttyS1, protocolo del DNS-320L)
cat > "$DEST/usr/local/sbin/dns340l-ventilador" <<'EOF'
#!/bin/bash
# Control del ventilador del DNS-340L por temperatura de discos y CPU.
TTY=/dev/ttyS1
mcu() { printf "\xfa$1\xfb" > "$TTY"; }
stty -F "$TTY" 115200 cs8 -cstopb -parenb raw -echo
mcu '\x03\x01\x00\x00\x00'            # DeviceReady (LED de encendido fijo)
cpu_temp() {
	for h in /sys/class/hwmon/hwmon*; do
		grep -qi therm "$h/name" 2>/dev/null && { echo $(( $(cat "$h/temp1_input") / 1000 )); return; }
	done
	echo 0
}
estado=""
while true; do
	t=0
	for d in /dev/sd[a-d]; do
		v=$(smartctl -n standby -A "$d" 2>/dev/null | awk '$1==194 {print $10; exit}')
		[ -n "$v" ] && [ "$v" -gt "$t" ] && t=$v
	done
	c=$(cpu_temp)
	if   [ "$t" -ge 50 ] || [ "$c" -ge 85 ]; then n=maximo
	elif [ "$t" -ge 42 ] || [ "$c" -ge 75 ]; then n=medio
	else n=bajo; fi
	if [ "$n" != "$estado" ]; then
		case $n in
			maximo) mcu '\x02\x00\x02\x00\x00' ;;
			medio)  mcu '\x02\x00\x01\x00\x00' ;;
			bajo)   mcu '\x02\x00\x03\x00\x00' ;;
		esac
		logger -t ventilador "discos ${t}C, CPU ${c}C -> $n"
		estado=$n
	fi
	sleep 60
done
EOF
chmod 755 "$DEST/usr/local/sbin/dns340l-ventilador"

cat > "$DEST/etc/systemd/system/dns340l-ventilador.service" <<'EOF'
[Unit]
Description=Control del ventilador del DNS-340L
After=local-fs.target

[Service]
ExecStart=/usr/local/sbin/dns340l-ventilador
# Si el servicio se detiene o falla: ventilador al máximo por seguridad
ExecStopPost=/bin/sh -c "printf '\\372\\002\\000\\002\\000\\000\\373' > /dev/ttyS1"
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Al apagar: pedir al microcontrolador que corte la corriente
mkdir -p "$DEST/usr/lib/systemd/system-shutdown"
cat > "$DEST/usr/lib/systemd/system-shutdown/dns340l-apagar" <<'EOF'
#!/bin/sh
# $1 = poweroff | reboot | halt
if [ "$1" = poweroff ] && [ -c /dev/ttyS1 ]; then
	stty -F /dev/ttyS1 115200 cs8 -cstopb -parenb raw -echo
	printf '\372\003\003\001\001\001\373' > /dev/ttyS1   # DeviceShutdown
	sleep 2
fi
EOF
chmod 755 "$DEST/usr/lib/systemd/system-shutdown/dns340l-apagar"

# Servicios
for s in systemd-networkd systemd-resolved systemd-timesyncd ssh dns340l-ventilador; do
	chroot "$DEST" systemctl enable "$s"
done
chroot "$DEST" systemctl enable smartmontools 2>/dev/null || chroot "$DEST" systemctl enable smartd 2>/dev/null || true

# Paquetes adicionales: el chroot necesita /proc, /sys, /dev y DNS
cp /etc/resolv.conf "$DEST/etc/resolv.conf" 2>/dev/null || echo "nameserver 1.1.1.1" > "$DEST/etc/resolv.conf"
for d in proc sys dev; do mount --bind /$d "$DEST/$d"; done
desmontar() { for d in dev sys proc; do umount "$DEST/$d" 2>/dev/null || true; done; }
trap desmontar EXIT

# Núcleo oficial de Debian, arrancado con kexec desde la flash (ver initrd/init y debian/zz-dns340l)
DTB="$AQUI/armada-370-dlink-dns340l.dtb"
[ -f "$DTB" ] || DTB="$AQUI/../build/armada-370-dlink-dns340l.dtb"
if [ "$NUCLEO" = 1 ] && [ -f "$AQUI/zz-dns340l" ] && [ -f "$DTB" ]; then
	echo "== Núcleo oficial de Debian (linux-image-armmp)"
	mkdir -p "$DEST/etc/dns340l" "$DEST/etc/kernel/postinst.d" "$DEST/etc/initramfs/post-update.d"
	cp "$DTB" "$DEST/etc/dns340l/armada-370-dlink-dns340l.dtb"
	install -m 755 "$AQUI/zz-dns340l" "$DEST/etc/kernel/postinst.d/zz-dns340l"
	install -m 755 "$AQUI/zz-dns340l" "$DEST/etc/initramfs/post-update.d/zz-dns340l"
	chroot "$DEST" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
		apt-get install -y --no-install-recommends linux-image-armmp initramfs-tools zstd
else
	echo "== AVISO: sin núcleo de Debian (faltan zz-dns340l o armada-370-dlink-dns340l.dtb junto al script)"
fi

# Panel web Cockpit (https://IP:9090). Se activa por socket: solo consume memoria mientras se usa
if [ "$COCKPIT" = 1 ]; then
	echo "== Cockpit"
	chroot "$DEST" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
		apt-get install -y --no-install-recommends cockpit cockpit-storaged
fi

# Tailscale (repositorio oficial). Si no hubiera paquete armhf, no se interrumpe la preparación
if [ "$TAILSCALE" = 1 ]; then
	echo "== Tailscale"
	if curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
	        -o "$DEST/usr/share/keyrings/tailscale-archive-keyring.gpg" &&
	   curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list \
	        -o "$DEST/etc/apt/sources.list.d/tailscale.list"; then
		chroot "$DEST" /bin/sh -c 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y tailscale' \
			|| echo "== AVISO: no se pudo instalar Tailscale (instálalo después en el NAS)"
	else
		echo "== AVISO: no se pudo descargar el repositorio de Tailscale"
	fi
fi

desmontar; trap - EXIT
ln -sf ../run/systemd/resolve/stub-resolv.conf "$DEST/etc/resolv.conf"

# Usuario
chroot "$DEST" useradd -m -s /bin/bash -G sudo "$USUARIO"
echo
echo "== Contraseña para el usuario '$USUARIO' (la usarás para entrar por SSH):"
until chroot "$DEST" passwd "$USUARIO"; do echo "Inténtalo de nuevo"; done
chroot "$DEST" passwd -l root

# Limpieza
chroot "$DEST" apt-get clean
rm -f "$DEST"/var/lib/apt/lists/*_Packages "$DEST"/var/lib/apt/lists/*_Sources 2>/dev/null || true
rm -f "$DEST/etc/ssh/ssh_host_"*      # se regeneran en el primer arranque
cat > "$DEST/etc/systemd/system/regenerar-claves-ssh.service" <<'EOF'
[Unit]
Description=Generar claves de host SSH en el primer arranque
Before=ssh.service
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
EOF
chroot "$DEST" systemctl enable regenerar-claves-ssh

echo "== Empaquetando en $SALIDA"
tar -C "$DEST" --numeric-owner -cpzf "$SALIDA" .
[ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER" "$SALIDA"
ls -l "$SALIDA"
md5sum "$SALIDA"
echo "Listo. Copia dns340l-debian.tar.gz a la memoria USB (FAT32)."
