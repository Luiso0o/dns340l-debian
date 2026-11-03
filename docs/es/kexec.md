# kexec en el DNS-340L

El núcleo de la flash arranca el núcleo de Debian con `kexec`. En el DNS-340L hacen falta tres
preparativos antes de `kexec -e`; sin ellos el núcleo nuevo se cuelga o arranca con datos viejos.
`initrd/init` los hace siempre.

**Probado en un DNS-340L (equipo 2) el 3-11-2026**, a mano desde el sistema de prueba de la flash:
* al mismo núcleo 6.12 con un initrd de prueba: arranca completo y contesta en la red;
* al núcleo oficial de Debian `6.12.107+deb13-armmp` con su initramfs: ensambla los RAID, arranca
  systemd, monta el RAID de datos y entra por SSH.
Y de forma automática, con el `uInitrd` v6 grabado en la flash, en los dos equipos.

Además, el initramfs de Debian necesita las líneas `ARRAY` en `/etc/mdadm/mdadm.conf` (sin ellas no
encuentra el RAID del sistema y no arranca). `instalar-nas.sh` las añade y regenera el initramfs.

## 1. Encender todos los relojes del SoC

El núcleo de la flash apaga al arrancar los relojes que no usa (`clk: Disabling unused clocks`):
audio, los dos SATA internos, SD y TDM. U-Boot los deja todos encendidos. Si el núcleo nuevo toca un
bloque sin reloj antes de encenderlo, se cuelga sin dar ningún mensaje.

```sh
devmem 0xf1018220 32 $(( $(devmem 0xf1018220) | 0x5282823F ))
```

`0xF1018220` es `clock-gating-control` del Armada 370; la máscara reúne los bits de
`drivers/clk/mvebu/armada-370.c` (0–5, 9, 15, 17, 23, 25, 28, 30). Con Linux 6.12 el valor pasa de
`0xB1CC423E` a `0xF3CEC23F`.

## 2. Borrar la copia vieja del árbol de dispositivos

El núcleo de la flash lleva el árbol añadido al final del zImage. Su descompresor lo mezcla con los
ATAG de U-Boot (línea `root=/dev/ram` e initrd en `0xF00040`) y lo deja en la RAM justo detrás del
núcleo (en el equipo probado, en `0x00D31320`). Si el zImage que se lanza con kexec se descomprime en
el mismo sitio, su descompresor se reubica en esa zona, encuentra la copia vieja pegada a su `_edata`,
la toma por un árbol añadido y **descarta el que le pasa kexec**: se ve la línea de órdenes vieja y
`Initramfs unpacking failed: invalid magic`. Borrar los ATAG de `0x100` no lo arregla.

`herramientas/borrar-fdt-viejo.c` busca en `/dev/mem` las copias idénticas a `/sys/firmware/fdt` y
borra su marca (`borrar-fdt-viejo SI`). El árbol que prepara kexec es distinto y no lo toca.

## 3. Bajar la red antes del salto

`mvneta` (red del Armada 370) no tiene función de apagado: si las interfaces siguen activas, la
tarjeta sigue copiando paquetes en memoria que ya es del núcleo nuevo. `kexec -e` sin `-x` baja las
interfaces antes del salto; no uses `-x` salvo para depurar.

## Depuración sin consola serie

* `netconsole` del núcleo de la flash envía a `255.255.255.255` desde `192.168.1.250`: Windows
  descarta esos paquetes, pero Wireshark los ve (filtro `udp.port == 6666`, *Seguir → Secuencia UDP*).
* `echo 1 > /sys/module/kernel/parameters/initcall_debug` muestra cada dispositivo al apagarse.
* `kexec -e -x` mantiene la red hasta `Bye!` (solo para ver los últimos mensajes del núcleo viejo).
* El kexec del proyecto acepta `-d`: se ha quitado la marca `KEXEC_DEBUG`, que Linux 6.12 rechaza.
* Para comprobar si el salto en sí funciona sin depender de Linux: una imagen mínima con cabecera de
  zImage que mande al microcontrolador la orden de apagado (`FA 03 03 01 01 01 FB` por UART1).

## Pendiente

* El reinicio por software del SoC (`reboot: Restarting system`) deja la placa colgada. Debian reinicia a
  través del microcontrolador (`MCUReset`, ver [microcontrolador.md](microcontrolador.md)), pero un
  reinicio que haga el propio núcleo (por ejemplo tras un *kernel panic* con `panic=`) sigue colgándose.

Tras kexec, el USB 3.0 delantero (Etron EJ168) funciona (`Host supports USB 3.0 SuperSpeed`).
