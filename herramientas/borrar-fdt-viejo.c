// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * borrar-fdt-viejo: borra la marca del árbol de dispositivos con el que arrancó el núcleo de la
 * flash, justo antes de saltar con kexec.
 *
 * Por qué: el núcleo de la flash arranca con el árbol de dispositivos añadido al zImage
 * (appended DTB). El descompresor lo mezcla con los ATAG de U-Boot (línea de órdenes vieja y
 * dirección del initrd de la flash) y lo deja en la RAM, justo detrás del núcleo. Al lanzar con
 * kexec un zImage que se descomprime en el mismo sitio, su descompresor se reubica en la misma
 * zona, encuentra esa copia vieja «pegada» a su _edata, la toma por un árbol añadido y la usa en
 * lugar del que le pasa kexec: línea de órdenes vieja y un initrd que ya no existe.
 * (Probado en un DNS-340L con Linux 6.12: el núcleo nuevo ignoraba root= y log_buf_len=.)
 *
 * Qué hace: lee /sys/firmware/fdt (el árbol con el que arrancó este núcleo), busca en la RAM,
 * a través de /dev/mem, las copias idénticas y, con el argumento SI, pone a cero su marca
 * (0xd00dfeed). Solo toca copias exactas de ese árbol: el que va a usar kexec es distinto
 * (lleva otra línea de órdenes) y no se toca. Este núcleo ya no vuelve a leer ese árbol plano
 * (usa su copia desplegada), así que borrar la marca no le afecta.
 *
 * Uso: borrar-fdt-viejo        (solo busca y muestra)
 *      borrar-fdt-viejo SI     (busca y borra la marca)
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define RAM_INICIO 0x00000000UL
#define RAM_TAM    0x20000000UL   /* 512 MiB */
#define TROZO      0x00100000UL   /* 1 MiB */

int main(int argc, char **argv)
{
	int borrar = argc > 1 && strcmp(argv[1], "SI") == 0;
	unsigned char *fdt, *inv;
	size_t n = 0, cap = 65536;
	unsigned long base;
	int f, m, encontradas = 0, distintas = 0;
	ssize_t r;

	f = open("/sys/firmware/fdt", O_RDONLY);
	if (f < 0) { perror("/sys/firmware/fdt"); return 1; }
	fdt = malloc(cap);
	while ((r = read(f, fdt + n, cap - n)) > 0) {
		n += r;
		if (n == cap) { cap *= 2; fdt = realloc(fdt, cap); }
	}
	close(f);
	if (n < 64 || fdt[0] != 0xd0 || fdt[1] != 0x0d || fdt[2] != 0xfe || fdt[3] != 0xed) {
		fprintf(stderr, "/sys/firmware/fdt no parece un árbol de dispositivos\n");
		return 1;
	}
	/* Guardamos la referencia invertida para no encontrarnos a nosotros mismos en la RAM */
	inv = malloc(n);
	for (size_t i = 0; i < n; i++) inv[i] = fdt[i] ^ 0xff;
	memset(fdt, 0, n);
	free(fdt);
	printf("Árbol de arranque: %zu bytes\n", n);

	m = open("/dev/mem", borrar ? (O_RDWR | O_SYNC) : (O_RDONLY | O_SYNC));
	if (m < 0) { perror("/dev/mem"); return 1; }

	for (base = RAM_INICIO; base < RAM_INICIO + RAM_TAM; base += TROZO) {
		size_t tam = TROZO + n;              /* solapa para no partir una copia */
		if (base + tam > RAM_INICIO + RAM_TAM) tam = RAM_INICIO + RAM_TAM - base;
		unsigned char *p = mmap(NULL, tam, borrar ? (PROT_READ | PROT_WRITE) : PROT_READ,
					MAP_SHARED, m, base);
		if (p == MAP_FAILED) continue;
		for (size_t o = 0; o + n <= tam && o < TROZO; o += 8) {
			if (p[o] != 0xd0 || p[o + 1] != 0x0d || p[o + 2] != 0xfe || p[o + 3] != 0xed)
				continue;
			size_t i;
			for (i = 4; i < n; i++)
				if ((p[o + i] ^ 0xff) != inv[i]) break;
			if (i != n) {
				distintas++;   /* otros árboles (p. ej. los .dtb de Debian en la caché): no se tocan */
				continue;
			}
			encontradas++;
			printf("  0x%08lx: copia del árbol de arranque", base + o);
			if (borrar) {
				volatile uint32_t *marca = (volatile uint32_t *)(p + o);
				*marca = 0;
				msync(p, tam, MS_SYNC);
				printf(" -> marca borrada");
			}
			printf("\n");
		}
		munmap(p, tam);
	}
	close(m);
	printf("%d copia(s) encontrada(s)%s; %d árbol(es) distinto(s) sin tocar\n",
	       encontradas, borrar ? " y borrada(s)" : "", distintas);
	return 0;
}
