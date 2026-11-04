# DNS-340L hardware (revision A1)

Data obtained from firmware 1.08b01 (`dmesg`, `lspci`, `/proc/mtd`), from the original U-Boot and from tests
with Linux 6.12.

![Board](img/placa.jpg)

## Components

| Component | Details |
|---|---|
| Processor | Marvell Armada 370 (88F6707), PJ4B ARMv7 core, 1.2 GHz |
| Memory | 512 MiB DDR3 (SK hynix) |
| Flash | Hynix 256 MiB NAND (ID `0xad 0xda`), 2 KiB pages, 128 KiB blocks, 4-bit BCH ECC |
| Internal registers | `0xf1000000` (as U-Boot leaves them) |
| SATA | **Marvell 88SE9215** (PCIe `1b4b:9215`), AHCI, 4 ports at 6 Gbps → the 4 bays. A plain controller: the RAID is done in software |
| Armada internal SATA | 2 ports (`sata_mv`), not connected |
| USB 3.0 | **Etron EJ168** (PCIe `1b6f:7023`) → blue front port. Works at 5 Gbps with Debian's kernel started with kexec; when booting directly from U-Boot it stays in D3cold |
| USB 2.0 | Internal controllers `f1050000` (bus 1) and `f1051000` (bus 2) → the two rear ports |
| Network | 2 × `mvneta` with **Marvell 88E1510** PHY (id `0x01410dd1`) at MDIO addresses **0** (eth0) and **1** (eth1), `rgmii-id` mode |
| Microcontroller | **Weltrend WT6701** on `ttyS1` at 115200 → fan, power LED, clock, scheduled power-on, power off and reset. See [microcontroller.md](microcontroller.md) |
| I2C | Device at `0x4a` (the D-Link firmware registers it as `cs42l51`, inherited from the reference board). `mcu_upgrade` uses `/dev/i2c-0` to reprogram the microcontroller |
| Internal clock | The Armada RTC does not work ("not ticking"); the microcontroller keeps the time |
| Console | `ttyS0`, 115200 8N1. Three pins plus a separate hole in the middle of the board; RX is the separate hole ([serial-console.md](serial-console.md)) |

## PCIe

```
00:01.0  PCIe port 0  →  01:00.0  Etron EJ168 (xHCI)
00:02.0  PCIe port 1  →  02:00.0  Marvell 88SE9215 (AHCI)
```

## NAND partitions (D-Link firmware)

| mtd | Name | Offset | Size | Use in this project |
|---|---|---|---|---|
| mtd0 | u-boot | `0x0000000` | 5 MiB | Original U-Boot. **Do not touch.** Variables at `0x400000` (512 KiB) |
| mtd1 | uImage | `0x0500000` | 5 MiB | **Linux 6.12 kernel** (U-Boot reads 4 MiB) |
| mtd2 | ramdisk | `0x0a00000` | 5 MiB | **Boot / rescue program** (U-Boot reads 3 MiB) |
| mtd3 | image.cfs | `0x0f00000` | 206 MiB | D-Link system (unused) |
| mtd4 | rescue firmware | `0xdd00000` | 15 MiB | D-Link recovery (unused, kept read-only) |
| mtd5 | config | `0xec00000` | 10 MiB | D-Link configuration (UBIFS) |
| mtd6 | mydlink | `0xf600000` | 10 MiB | mydlink (UBIFS) |

Notes:
* The analysed unit had 10 bad blocks; one at `0x920000`, inside `mtd1` but beyond the 4 MiB that U-Boot reads.
* The `config` partition showed **~70,000 erase cycles** per block: the D-Link firmware writes to it
  continuously. Another reason not to use the NAND from Debian.
* The bad block table lives in the flash itself (two copies, pages 131008 and 130944, version 1). Linux finds
  it and does not need to create it.

## GPIO and MPP

Configuration of the `RD-88F6710_ALpha_DNS340L` board in U-Boot and in D-Link's kernel (identical except where
noted):

* **MPP** (registers `0xf1018000`–`0xf1018020`): `0x11101111 0x11111111 0x22222111 0x02222222 0x11111110 0x01111111 0x00000000 0x00220000 0x00000000`.
  MPP 47–59 are GPIOs; MPP 60–61 are `uart1` (microcontroller). Note: `armada-370.dtsi` puts `uart1` on
  MPP41/42, which are NAND data lines on this board; the project's device tree moves it to MPP60/61.
* **Outputs** (bank 1): GPIO 47–59.
* **Initial values**: U-Boot sets GPIOs **48, 49, 50** to 1; D-Link's kernel sets **47, 48, 49** to 1 (and 50 to 0).
* **GPIO 47–49 = power for the bays** (tested on unit 2): setting them to 0 instantly cuts the power to all
  four disks. They are probably meant for staggered disk spin-up. The device tree reserves them (`gpio-hog`),
  always at 1. **Do not touch them.**
* **LEDs**: D-Link's `led` program writes bits 18, 19, 25, 26 and 27 of registers `0x18140` (output) and
  `0x18148` (blink) → **GPIO 50, 51, 57, 58, 59**. Tested on unit 2:

  | GPIO | Function |
  |---|---|
  | 50 | white power LED (1 = on) |
  | 59 | orange power LED (1 = on) |
  | 58 | power LED: at 1 it stops blinking (unconfirmed) |
  | 51 | orange disk activity light, unconfirmed; set to 1 as in the D-Link firmware |
  | 57 | no visible effect |

  The bay LEDs (white = disk OK, blinking orange = activity, steady orange = failure, according to D-Link's
  manual) are driven by the SATA controller.
* **RJ45 LEDs**: driven by the PHY (page 3, register 16). Linux sets `0x1177`, where the activity LED only
  lights with a 100 Mbps link, so it never lit at 1 Gbps. The device tree sets `0x1140` with
  `marvell,reg-init` (LED0 = link, LED1 = blinks with traffic). Tested on unit 2.
* High value on GPIO 4 (bank 0) and GPIO 65 (bank 2) in both cases.
* **D-Link firmware running** (second unit, read with `devmem`): same MPP as above; outputs GPIO 47–59
  (`0xf1018144` = `0xF0007FFF`), high on **47–51** and low on 52–59 (`0xf1018140` = `0x800F8000`); banks 0
  and 2 without outputs. No D-Link script touches GPIOs for USB 3.0: the Etron runs with Etron's own driver
  (`etxhci_hcd_131016`, built into the kernel).
* **PCIe with the D-Link firmware:** both links up (`0xf1041a04` = `0x00010000`, `0xf1081a04` = `0x00010100`,
  bit 0 = 0); Etron on port 0 (bus 0), 88SE9215 on port 1 (bus 1). PCI configuration read from both chips:

  | | Etron EJ168 (USB 3.0) | Marvell 88SE9215 (SATA) |
  |---|---|---|
  | Power state | D0 | D0 |
  | ASPM (link power saving) | **disabled** (supports L0s and L1) | **disabled** |
  | Link speed | 2.5 GT/s ×1 (supports 5 GT/s) | 5 GT/s ×1 |

## Buttons

Tested on unit 2 with Debian, counting interrupts in `/proc/interrupts`:

| Button | GPIO | Result |
|---|---|---|
| Reset (rear) | 64 (bank 2, bit 0), active low | ✅ reaches Linux (`gpio-keys`, `KEY_PROG1`) |
| USB copy (front) | 63 (bank 1, bit 31), active low | ✅ reaches Linux (`gpio-keys`, `KEY_COPY`) |
| Power | — | ❌ does not change GPIO 65 or any free input, sends nothing on `ttyS1` and, held for 15 s, does not power off. With Debian it only powers the unit on |

## Maximum volume size

The kernel is **32-bit**: a block device cannot exceed **16 TiB**. With 4 × 4 TB in RAID 5 (10.9 TiB) there
is no problem; with 8 TB disks, `instalar-nas.sh` caps the data volume at 16 TiB and warns about it (using all
of it would require splitting the data into two RAIDs).
