// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * borrar_env: borra ÚNICAMENTE la zona de variables de U-Boot del DNS-340L.
 *   Dispositivo : /dev/mtd0 ("u-Boot", 5 MiB, bloques de 128 KiB)
 *   Zona        : 0x400000 - 0x47FFFF (4 bloques)
 * No admite otros dispositivos, posiciones ni tamaños: están fijos en el código.
 * Uso: borrar_env SI-BORRAR-ENV
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <mtd/mtd-user.h>

#define DISPOSITIVO   "/dev/mtd0"
#define NOMBRE_MTD    "\"u-Boot\""
#define TAM_MTD       0x500000u
#define TAM_BLOQUE    0x20000u
#define INICIO_ENV    0x400000u
#define TAM_ENV       0x80000u
#define CONFIRMACION  "SI-BORRAR-ENV"

static int comprobar_proc_mtd(void)
{
	char linea[256];
	int ok = 0;
	FILE *f = fopen("/proc/mtd", "r");
	if (!f) { perror("/proc/mtd"); return 0; }
	while (fgets(linea, sizeof linea, f)) {
		if (strncmp(linea, "mtd0:", 5) == 0) {
			unsigned tam, eb;
			if (sscanf(linea + 5, "%x %x", &tam, &eb) == 2 &&
			    tam == TAM_MTD && eb == TAM_BLOQUE && strstr(linea, NOMBRE_MTD))
				ok = 1;
			break;
		}
	}
	fclose(f);
	return ok;
}

int main(int argc, char **argv)
{
	static unsigned char buf[TAM_BLOQUE];
	struct mtd_info_user info;
	unsigned off;
	int fd, i;

	if (argc != 2 || strcmp(argv[1], CONFIRMACION) != 0) {
		fprintf(stderr, "Uso: %s %s\n"
			"Borra solo 0x%X-0x%X de %s (variables de U-Boot).\n",
			argv[0], CONFIRMACION, INICIO_ENV, INICIO_ENV + TAM_ENV - 1, DISPOSITIVO);
		return 2;
	}
	if (!comprobar_proc_mtd()) {
		fprintf(stderr, "ABORTADO: mtd0 no es \"u-Boot\" de 0x%X con bloques de 0x%X\n",
			TAM_MTD, TAM_BLOQUE);
		return 3;
	}
	fd = open(DISPOSITIVO, O_RDWR);
	if (fd < 0) { perror(DISPOSITIVO); return 4; }
	if (ioctl(fd, MEMGETINFO, &info) != 0) { perror("MEMGETINFO"); return 5; }
	if (info.size != TAM_MTD || info.erasesize != TAM_BLOQUE || info.type != MTD_NANDFLASH) {
		fprintf(stderr, "ABORTADO: geometría inesperada (size 0x%X, erasesize 0x%X, tipo %u)\n",
			info.size, info.erasesize, info.type);
		return 6;
	}

	/* Primero se comprueba que ninguno de los 4 bloques está marcado como defectuoso */
	for (off = INICIO_ENV; off < INICIO_ENV + TAM_ENV; off += TAM_BLOQUE) {
		loff_t o = off;
		int r = ioctl(fd, MEMGETBADBLOCK, &o);
		if (r < 0) { perror("MEMGETBADBLOCK"); return 7; }
		if (r > 0) { fprintf(stderr, "ABORTADO: bloque 0x%X defectuoso\n", off); return 8; }
	}

	for (off = INICIO_ENV; off < INICIO_ENV + TAM_ENV; off += TAM_BLOQUE) {
		struct erase_info_user e;
		/* Doble comprobación de límites antes de cada borrado */
		if (off < INICIO_ENV || off + TAM_BLOQUE > INICIO_ENV + TAM_ENV) {
			fprintf(stderr, "ABORTADO: fuera de límites 0x%X\n", off); return 9;
		}
		e.start = off;
		e.length = TAM_BLOQUE;
		printf("Borrando bloque 0x%X ... ", off); fflush(stdout);
		if (ioctl(fd, MEMERASE, &e) != 0) { perror("MEMERASE"); return 10; }

		/* Verificación: el bloque debe leerse todo a 0xFF */
		if (lseek(fd, off, SEEK_SET) != (off_t)off ||
		    read(fd, buf, TAM_BLOQUE) != (ssize_t)TAM_BLOQUE) {
			perror("lectura de verificación"); return 11;
		}
		for (i = 0; i < (int)TAM_BLOQUE; i++)
			if (buf[i] != 0xFF) { printf("ERROR: byte 0x%X no es FF\n", off + i); return 12; }
		printf("ok (todo FF)\n");
	}
	close(fd);
	printf("Zona de variables 0x%X-0x%X borrada y verificada.\n",
	       INICIO_ENV, INICIO_ENV + TAM_ENV - 1);
	return 0;
}
