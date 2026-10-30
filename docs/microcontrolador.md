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
| DeviceShutdown | `03 03 01 01 01` | Apagado (corta la alimentación) |
| MCUReset | `03 03 02 01 ..` | |
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

Según `up_read_daemon`: `PWR` y `PWRPush` (botón de encendido), `RTCAlarm`, respuestas de `ThermalGet`,
`FanStatusGet`, `APRStatus`, `WOLStatus`, `MCUVer` y lecturas del reloj. El formato exacto de estos mensajes
está pendiente de documentar.

## Uso en este proyecto

* `initrd/init`: DeviceReady y ventilador a media al arrancar.
* `initrd/rescate.sh`: ventilador al máximo (señal de modo rescate) y a media al obtener IP.
* Debian: servicio `dns340l-ventilador` (por temperatura de discos y CPU) y `system-shutdown/dns340l-apagar` (DeviceShutdown al apagar).
