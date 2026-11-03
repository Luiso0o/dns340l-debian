# Microcontrolador Weltrend WT6701

El ventilador, el LED de encendido, el botón de encendido, el reloj y el encendido programado los gestiona un
microcontrolador **Weltrend WT6701** conectado al **`ttyS1`** del procesador (MPP 60–61, `uart1`).

El protocolo es **el mismo que el del DNS-320L**. Se ha extraído de la tabla de órdenes de `up_send_ctl`
(firmware 1.08b01) y coincide byte a byte con lo documentado para el DNS-320L.

## Puerto

`/dev/ttyS1`, **115200 8N1**, modo *raw*:

```sh
stty -F /dev/ttyS1 115200 cs8 -cstopb -parenb raw -echo
```

## Formato de trama

7 bytes: `FA` + 5 bytes + `FB`. Los cuatro primeros bytes de datos identifican la orden; el quinto es el parámetro.

```sh
printf '\372\002\000\001\000\000\373' > /dev/ttyS1    # FA 02 00 01 00 00 FB = ventilador a media
```

## Órdenes

✅ = probada en un DNS-340L con Linux 6.12.

| Orden | Bytes (entre FA y FB) | Notas |
|---|---|---|
| FanStop | `02 00 00 00 00` | Ventilador parado |
| FanHalf | `02 00 01 00 00` | ✅ Velocidad media |
| FanFull | `02 00 02 00 00` | ✅ Velocidad máxima |
| FanLow | `02 00 03 00 00` | Velocidad baja |
| DeviceReady | `03 01 00 00 00` | ✅ Sistema arrancado: LED de encendido fijo |
| APREnable / APRDisable / APRStatus | `03 02 01 ..` / `03 02 00 ..` / `03 02 02 ..` | Encendido automático al volver la corriente |
| DeviceShutdown | `03 03 01 01 01` | ✅ Apagado (corta la alimentación) |
| MCUReset | `03 03 02 01 01` | ✅ Reinicia la placa entera (corta y devuelve la corriente). Es la única forma de reiniciar: el reinicio por software del SoC la deja colgada |
| DeviceShutdownByUPS | `03 03 03 01 ..` | |
| MCUVer | `03 05 00 00 00` | Respuesta: versión `1.xx` |
| PWRLed | `03 06 ..` | LED de encendido (parámetro: apagado / encendido / parpadeo) |
| MFGMode | `03 07 ..` | Modo de fábrica |
| ThermalGet | `03 08 00 00 00` | Lectura del termistor (se convierte con una tabla) |
| FanStatusGet | `03 09 00 00 00` | Estado del ventilador |
| WOLStatus Enable / Disable / Get | `03 0A 01` / `03 0A 00` / `03 0A 02` | Wake-on-LAN |
| RPWMValue / WPWMValue | `03 0B 00` / `03 0B 01 vv` | PWM del ventilador (0–255) |
| RPWMClock / WPWMClock | `03 0C 00` / `03 0C 01 vv` | Frecuencia del PWM |
| Reloj: leer | `01 01 ii 00 00` | `ii`: 00 centésimas, 01 seg, 02 min, 03 hora, 04 día semana, 05 día, 06 mes, 07 año, 08 fecha completa |
| Reloj: escribir | `01 02 ii vv 00` | Mismos índices |
| Alarma: leer/escribir | `01 01 0A..0F` / `01 02 0A..0E` | Mes, día, hora, minuto, segundo, indicador |
| Alarma: activar / desactivar | `01 02 10 01` / `01 02 10 00` | Encendido programado |

## Mensajes que envía el microcontrolador

Obtenido del desensamblado de `up_read_daemon` (firmware 1.08b01 de D-Link) y de una captura en vivo de `ttyS1`
en un segundo DNS-340L (con `up_read_daemon` parado).
Lee `ttyS1` byte a byte y reconoce dos formatos:

* **7 bytes**: `FA b1 b2 b3 b4 b5 FB`. Identifica el mensaje por `b1 b2 b3`.
* **13 bytes**: `FA` + 11 bytes + `FB`: fecha y hora completas del reloj (respuesta a «Reloj: leer» `08`).
  Los valores van en BCD (`0x59` = 59).

| Mensaje | Trama | Qué hace D-Link |
|---|---|---|
| `PWR` | `FA 21 00 00 .. .. FB` | **Botón de encendido pulsado**: escribe `Button:PWR` en `/runtime/button` y apaga el equipo |
| `PWRPush` | `FA 23 00 00 .. .. FB` | Pulsación en modo de fábrica (`/runtime/MFG`) |
| `RTCAlarm` | `FA 20 00 00 .. .. FB` | Alarma del reloj: ejecuta `schedule_poweron -s` |
| `ACK` | `FA 30 00 00 .. .. FB` | Confirmación de una orden (`/runtime/mcu/ack`) |
| `MCUVer` | `FA 03 05 00 vv .. FB` | Versión `1.vv` (BCD) |
| Respuestas | `FA 03 08 00 vv .. FB`, `FA 03 09 ..`, `FA 03 02 02 ..`, `FA 03 0A 02 ..`, `FA 03 0B ..`, `FA 03 0C ..` | ThermalGet, FanStatusGet, APRStatus, WOLStatus, RPWM, RPWMClock |
| Reloj | `FA 01 01 ii vv .. FB` | Lectura de un campo del reloj (índices de la tabla anterior) |

**Captura en vivo** (unos 4 minutos, con `up_send_daemon` preguntando cada pocos segundos):

```
fa 03 09 00 00 d1 fb   FanStatusGet: estado del ventilador en el 5.º byte (d0–d3)
fa 03 08 00 00 7a fb   ThermalGet: valor del termistor en el 5.º byte (0x7a–0x7b, se convierte con una tabla)
fa 30 00 00 00 00 fb   ACK después de cada respuesta
```

Con **pulsaciones cortas del botón de encendido no llegó ninguna trama** `FA 21`.

**Prueba en el equipo 2 con Debian (3-11-2026):** la recepción por `ttyS1` funciona (a `MCUVer` contesta
`FA 03 05 00 01 06 FB` y `FA 30 … FB`), pero el botón de encendido, ni corto ni mantenido 6 segundos,
**no manda nada por `ttyS1`, no cambia ningún GPIO de entrada libre (tampoco el 65) ni corta la
corriente**. Con Debian el botón solo sirve para encender. Pendiente: averiguar si el microcontrolador
necesita alguna orden previa para avisar, o si va a una patilla configurada con otra función.

`up_send_daemon` es el único que escribe en `ttyS1` en el firmware de D-Link (recibe las órdenes de
`up_send_ctl` por una cola de mensajes System V). Para Debian bastará un único proceso que abra `ttyS1`,
envíe las órdenes del ventilador y lea las respuestas.

## Uso en este proyecto

* `initrd/init`: DeviceReady y ventilador a media al arrancar.
* `initrd/rescate.sh`: ventilador al máximo (señal de modo rescate) y a media al obtener IP.
* Debian: servicio `dns340l-ventilador` (por temperatura de discos y CPU) y `system-shutdown/dns340l-apagar` (DeviceShutdown al apagar).
