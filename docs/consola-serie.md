# Consola serie

No es imprescindible para instalar (se puede grabar todo desde el firmware de D-Link), pero es **la red de
seguridad**: con ella se entra en U-Boot y se puede arrancar o grabar cualquier núcleo por TFTP.

## Conector

Hay que abrir la carcasa. La consola es un conector de **3 pines** en el centro de la placa, debajo de la
bobina marcada "4R7", entre el chip Etron y el procesador.

![Consola serie](img/consola-serie.jpg)

| Pin (con los conectores de red hacia abajo) | Señal | Adaptador USB-TTL |
|---|---|---|
| Izquierdo | TX del NAS | **RXD** |
| Central | GND | **GND** |
| Derecho | RX del NAS | **TXD** |

* El pin de **VCC del adaptador no se conecta**.
* Usa un adaptador de **3,3 V** (CP2102, FT232RL…).
* Parámetros: **115200 8N1**, sin control de flujo.
* El agujero cuadrado que hay a la derecha, fuera del recuadro, no se ha identificado: no conectar.

Otros conectores de la placa:
* **JP1** (4 pines, junto a la 3.ª bahía): ninguno de sus pines es masa; función desconocida.
* **JP4** (4 pines, junto al Weltrend): programación del microcontrolador. **No usar.**
* **2 × 5 pines** (junto a la memoria): JTAG.

## Identificar los pines con un polímetro

1. Apagado, en continuidad: el pin que pita con la carcasa metálica de un USB es **GND**.
2. Encendido, en tensión continua: el pin cuya tensión **oscila** durante el arranque es **TX**; el que se queda fijo en ~3,3 V es **RX**.

## Entrar en U-Boot

Encender el NAS y pulsar una tecla durante la cuenta atrás. Aparece `Marvell>>`.
U-Boot: `U-Boot 2011.12 (Mar 10 2014) Marvell version: v2011.12 2013_Q1.2`.
