# Weltrend WT6701 microcontroller

The fan, the power LED, the clock, scheduled power-on, power off and board reset are handled by a
**Weltrend WT6701** microcontroller connected to the processor's **`ttyS1`** (MPP 60–61, `uart1`).

The protocol is **the same as on the DNS-320L**. It was extracted from the command table of `up_send_ctl`
(firmware 1.08b01) and matches byte for byte what is documented for the DNS-320L.

## Port

`/dev/ttyS1`, **115200 8N1**, raw mode:

```sh
stty -F /dev/ttyS1 115200 cs8 -cstopb -parenb raw -echo
```

## Frame format

7 bytes: `FA` + 5 bytes + `FB`. The first four data bytes identify the command; the fifth is the parameter.

```sh
printf '\372\002\000\001\000\000\373' > /dev/ttyS1    # FA 02 00 01 00 00 FB = fan at medium speed
```

## Commands

✅ = tested on a DNS-340L with Linux 6.12.

| Command | Bytes (between FA and FB) | Notes |
|---|---|---|
| FanStop | `02 00 00 00 00` | Fan stopped |
| FanHalf | `02 00 01 00 00` | ✅ Medium speed |
| FanFull | `02 00 02 00 00` | ✅ Full speed |
| FanLow | `02 00 03 00 00` | Low speed |
| DeviceReady | `03 01 00 00 00` | ✅ System up: power LED steady |
| APREnable / APRDisable / APRStatus | `03 02 01 ..` / `03 02 00 ..` / `03 02 02 ..` | Automatic power-on when mains power returns |
| DeviceShutdown | `03 03 01 01 01` | ✅ Power off (cuts the power) |
| MCUReset | `03 03 02 01 01` | ✅ Resets the whole board (cuts and restores the power). The only way to reboot: the SoC's software reset leaves the board hung |
| DeviceShutdownByUPS | `03 03 03 01 ..` | |
| MCUVer | `03 05 00 00 00` | ✅ Reply: version (`FA 03 05 00 01 06 FB` on unit 2) |
| PWRLed | `03 06 ..` | Power LED (parameter: off / on / blink) |
| MFGMode | `03 07 ..` | Factory mode |
| ThermalGet | `03 08 00 00 00` | Thermistor reading (converted with a table) |
| FanStatusGet | `03 09 00 00 00` | Fan status |
| WOLStatus Enable / Disable / Get | `03 0A 01` / `03 0A 00` / `03 0A 02` | Wake-on-LAN |
| RPWMValue / WPWMValue | `03 0B 00` / `03 0B 01 vv` | Fan PWM (0–255) |
| RPWMClock / WPWMClock | `03 0C 00` / `03 0C 01 vv` | PWM frequency |
| Clock: read | `01 01 ii 00 00` | `ii`: 00 hundredths, 01 sec, 02 min, 03 hour, 04 weekday, 05 day, 06 month, 07 year, 08 full date |
| Clock: write | `01 02 ii vv 00` | Same indices |
| Alarm: read/write | `01 01 0A..0F` / `01 02 0A..0E` | Month, day, hour, minute, second, flag |
| Alarm: enable / disable | `01 02 10 01` / `01 02 10 00` | Scheduled power-on |

## Messages sent by the microcontroller

From the disassembly of `up_read_daemon` (D-Link firmware 1.08b01) and a live capture of `ttyS1` on a second
DNS-340L (with `up_read_daemon` stopped). It reads `ttyS1` byte by byte and recognises two formats:

* **7 bytes**: `FA b1 b2 b3 b4 b5 FB`. The message is identified by `b1 b2 b3`.
* **13 bytes**: `FA` + 11 bytes + `FB`: full date and time of the clock (reply to "Clock: read" `08`).
  Values are BCD (`0x59` = 59).

| Message | Frame | What D-Link does |
|---|---|---|
| `PWR` | `FA 21 00 00 .. .. FB` | **Power button pressed**: writes `Button:PWR` to `/runtime/button` and shuts down |
| `PWRPush` | `FA 23 00 00 .. .. FB` | Press in factory mode (`/runtime/MFG`) |
| `RTCAlarm` | `FA 20 00 00 .. .. FB` | Clock alarm: runs `schedule_poweron -s` |
| `ACK` | `FA 30 00 00 .. .. FB` | Command acknowledgement (`/runtime/mcu/ack`) |
| `MCUVer` | `FA 03 05 00 vv .. FB` | Version `1.vv` (BCD) |
| Replies | `FA 03 08 00 vv .. FB`, `FA 03 09 ..`, `FA 03 02 02 ..`, `FA 03 0A 02 ..`, `FA 03 0B ..`, `FA 03 0C ..` | ThermalGet, FanStatusGet, APRStatus, WOLStatus, RPWM, RPWMClock |
| Clock | `FA 01 01 ii vv .. FB` | One clock field (indices from the previous table) |

**Live capture** (about 4 minutes, with `up_send_daemon` polling every few seconds):

```
fa 03 09 00 00 d1 fb   FanStatusGet: fan status in the 5th byte (d0–d3)
fa 03 08 00 00 7a fb   ThermalGet: thermistor value in the 5th byte (0x7a–0x7b, converted with a table)
fa 30 00 00 00 00 fb   ACK after each reply
```

**Power button, tested on unit 2 with Debian (3 November 2026):** reception on `ttyS1` works (`MCUVer` is
answered with `FA 03 05 00 01 06 FB` and `FA 30 … FB`), but the power button, whether pressed briefly or held
for 15 seconds, **sends nothing on `ttyS1`, changes no free input GPIO (not GPIO 65 either) and does not cut
the power**. With Debian the button only powers the unit on. Open question: whether the microcontroller needs
some initial command to report it, or whether the button goes to a pin configured for another function.

In the D-Link firmware `up_send_daemon` is the only process writing to `ttyS1` (it receives commands from
`up_send_ctl` through a System V message queue).

## Use in this project

* `initrd/init`: DeviceReady and medium fan speed at boot.
* `initrd/rescate.sh`: full fan speed (rescue mode signal) and medium speed once it has an IP address.
* Debian: `dns340l-ventilador` service (fan speed from disk and CPU temperatures) and
  `system-shutdown/dns340l-apagar` (DeviceShutdown on power off and MCUReset on reboot).
