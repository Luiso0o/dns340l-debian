// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * nand340: lee y graba la NAND del DNS-340L desde Linux SIN controlador MTD, manejando el controlador
 * de NAND del Armada 370 directamente por /dev/mem. Sirve para actualizar mtd1/mtd2 desde el sistema
 * de prueba v1 (núcleo sin MTD ni kexec) cuando la consola serie no recibe.
 *
 * Reproduce las secuencias del controlador de Linux (drivers/mtd/nand/raw/marvell_nand.c, NFCv2,
 * disposición 2048/512/BCH-4: un solo trozo de 2048 datos + 32 de reserva) y usa la configuración que
 * deja U-Boot en el controlador (NDCR, tiempos, BCH), que es la misma con la que U-Boot lee al arrancar.
 *
 * Seguridad:
 *  - Solo escribe en mtd1 (0x500000-0x9FFFFF), mtd2 (0xA00000-0xEFFFFF) y en una zona de prueba de
 *    image.cfs (0x2000000-0x203FFFF). NUNCA por debajo de 0x500000 (U-Boot).
 *  - Salta los bloques defectuosos conocidos (tabla de U-Boot de este equipo), como "nand write.e".
 *  - Tras grabar cada bloque lo vuelve a leer y compara; si no coincide, se detiene.
 *  - Las órdenes de escritura exigen el argumento SI-GRABAR.
 *
 * Uso:
 *   nand340 info
 *   nand340 leer   DESPLAZAMIENTO LONGITUD FICHERO        (como "nand read.e")
 *   nand340 grabar DESPLAZAMIENTO FICHERO SI-GRABAR         (borra, graba y verifica; como "nand write.e")
 *   nand340 prueba SI-GRABAR                                (graba datos al azar en la zona de prueba y verifica)
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define REGS_FISICOS   0xf1000000u
#define NFC_OFF        0xd0000u
#define CLK_OFF        0x18740u          /* reloj del divisor de núcleo: bit 25 = reloj de la NAND */
#define CLK_NAND       (1u << 25)

#define NDCR      0x00
#define NDSR      0x14
#define NDECCCTRL 0x28
#define NDDB      0x40
#define NDCB0     0x48

#define NDCR_ND_RUN   (1u << 28)
#define NDCR_ECC_EN   (1u << 30)
#define NDCR_SPARE_EN (1u << 31)
#define NDCR_DMA_EN   (1u << 29)
#define NDSR_WRCMDREQ (1u << 0)
#define NDSR_RDDREQ   (1u << 1)
#define NDSR_WRDREQ   (1u << 2)
#define NDSR_CORERR   (1u << 3)
#define NDSR_UNCERR   (1u << 4)
#define NDSR_CMDD     (1u << 8)
#define NDSR_RDY      (1u << 11)
#define NDSR_ERRCNT(x) (((x) >> 16) & 0x1f)

#define CMD1(x)     ((uint32_t)(x) & 0xff)
#define CMD2(x)     (((uint32_t)(x) & 0xff) << 8)
#define ADDR_CYC(x) (((uint32_t)(x) & 7) << 16)
#define DBC         (1u << 19)
#define CMD_TYPE(x) (((uint32_t)(x) & 7) << 21)
#define LEN_OVRD    (1u << 28)
#define XTYPE(x)    (((uint32_t)(x) & 7) << 29)
#define T_READ  0
#define T_WRITE 1
#define T_ERASE 2

#define PAGINA    2048u
#define RESERVA   32u
#define BLOQUE    (128u * 1024u)
#define PAG_BLOQUE (BLOQUE / PAGINA)
#define TOTAL     (256u * 1024u * 1024u)

/* Bloques defectuosos según la tabla de U-Boot de este equipo (arranque del 2-11-2026) */
static const uint32_t defectuosos[] = {
	0x000920000, 0x0081a0000, 0x00c140000, 0x00c160000, 0x00cbc0000,
	0x00cbe0000, 0x00d4c0000, 0x00d4e0000, 0x00df40000, 0x00df60000,
};

static volatile uint32_t *nfc, *clk;

static int es_defectuoso(uint32_t off)
{
	for (unsigned i = 0; i < sizeof(defectuosos) / sizeof(defectuosos[0]); i++)
		if ((off & ~(BLOQUE - 1)) == defectuosos[i])
			return 1;
	return 0;
}

static int zona_escribible(uint32_t ini, uint32_t fin)  /* [ini, fin) */
{
	if (ini < 0x500000u || fin <= ini)
		return 0;
	if (fin <= 0xF00000u)                               /* mtd1 + mtd2 */
		return 1;
	if (ini >= 0x2000000u && fin <= 0x2040000u)         /* zona de prueba en image.cfs */
		return 1;
	return 0;
}

static uint32_t rd(unsigned off) { return nfc[off / 4]; }
static void wr(unsigned off, uint32_t v) { nfc[off / 4] = v; }

static double ahora(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

/* Espera a que NDSR tenga algún bit de 'mascara'; lo borra si 'borrar' */
static int espera_sr(uint32_t mascara, int borrar, double seg, const char *que)
{
	double lim = ahora() + seg;
	uint32_t v;
	while (!((v = rd(NDSR)) & mascara)) {
		if (ahora() > lim) {
			fprintf(stderr, "Tiempo agotado esperando %s (NDSR=0x%08x NDCR=0x%08x)\n",
				que, v, rd(NDCR));
			return -1;
		}
	}
	if (borrar)
		wr(NDSR, mascara);
	return 0;
}

static int espera_ndrun(double seg)
{
	double lim = ahora() + seg;
	while (rd(NDCR) & NDCR_ND_RUN) {
		if (ahora() > lim) {
			fprintf(stderr, "Tiempo agotado: ND_RUN no se libera (NDSR=0x%08x)\n", rd(NDSR));
			wr(NDCR, rd(NDCR) & ~NDCR_ND_RUN);
			return -1;
		}
	}
	return 0;
}

static int prepara(void)
{
	if (espera_ndrun(0.2))
		return -1;
	wr(NDSR, rd(NDSR));                     /* limpiar estado */
	wr(NDCR, rd(NDCR) | NDCR_ND_RUN);
	if (espera_sr(NDSR_WRCMDREQ, 1, 0.2, "WRCMDREQ"))
		return -1;
	return 0;
}

static void envia(uint32_t c0, uint32_t c1, uint32_t c2, uint32_t c3)
{
	wr(NDCB0, c0);
	wr(NDCB0, c1);
	wr(NDCB0, c2);
	if (c0 & LEN_OVRD)
		wr(NDCB0, c3);
}

/* Lee una página con ECC. Devuelve 0 bien (bits corregidos en *bf), 1 página vacía (borrada), -1 error */
static int lee_pagina(uint32_t pag, uint8_t *buf, int *bf)
{
	uint32_t *p = (uint32_t *)buf;
	uint32_t sr;
	if (prepara())
		return -1;
	envia(CMD_TYPE(T_READ) | ADDR_CYC(5) | LEN_OVRD | DBC | CMD1(0x00) | CMD2(0x30) | XTYPE(0),
	      pag << 16, (pag >> 16) & 0xff, PAGINA + RESERVA);
	for (unsigned i = 0; i < (PAGINA + RESERVA) / 4; i += 8) {
		if (espera_sr(NDSR_RDDREQ, 1, 0.2, "RDDREQ"))
			return -1;
		for (unsigned k = 0; k < 8; k++)
			p[i + k] = nfc[NDDB / 4];
	}
	sr = rd(NDSR);
	espera_ndrun(0.2);
	*bf = 0;
	if (sr & NDSR_UNCERR) {
		wr(NDSR, sr);
		for (unsigned i = 0; i < PAGINA; i++)
			if (buf[i] != 0xff)
				return -2;          /* error de ECC real */
		return 1;                       /* página borrada: normal */
	}
	if (sr & NDSR_CORERR) {
		wr(NDSR, sr);
		*bf = NDSR_ERRCNT(sr);
	}
	return 0;
}

/* Lectura sin ECC (para diagnóstico): 2048 + 64 bytes tal cual están en la NAND.
 * 'ra' = 1 usa el direccionamiento normal (página en los bytes 3-5), 0 el alternativo. */
static int lee_cruda(uint32_t pag, uint8_t *buf, int ra)
{
	uint32_t *p = (uint32_t *)buf;
	uint32_t ndcr = rd(NDCR), ecc = rd(NDECCCTRL), r = 0;
	wr(NDCR, ndcr & ~NDCR_ECC_EN);
	wr(NDECCCTRL, ecc & ~1u);
	if (prepara()) { r = -1; goto fin; }
	envia(CMD_TYPE(T_READ) | ADDR_CYC(5) | LEN_OVRD | DBC | CMD1(0x00) | CMD2(0x30) | XTYPE(0),
	      ra ? pag << 16 : pag << 8, ra ? (pag >> 16) & 0xff : (pag >> 24) & 0xff, PAGINA + 64);
	for (unsigned i = 0; i < (PAGINA + 64) / 4; i += 8) {
		if (espera_sr(NDSR_RDDREQ, 1, 0.2, "RDDREQ (crudo)")) { r = -1; goto fin; }
		for (unsigned k = 0; k < 8; k++)
			p[i + k] = nfc[NDDB / 4];
	}
	espera_ndrun(0.2);
fin:
	wr(NDCR, ndcr);
	wr(NDECCCTRL, ecc);
	return r;
}

/* RESET (0xFF) y READ ID (0x90): comprueba que las órdenes llegan al chip (solo lectura) */
static int identifica(void)
{
	uint32_t w[2];
	if (prepara()) return -1;
	envia(CMD_TYPE(5) | CMD1(0xff), 0, 0, 0);
	if (espera_sr(NDSR_CMDD, 1, 0.5, "CMDD (reset)")) return -1;
	espera_sr(NDSR_RDY, 1, 0.5, "RDY (reset)");
	espera_ndrun(0.2);
	if (prepara()) return -1;
	envia(CMD_TYPE(3) | ADDR_CYC(1) | CMD1(0x90), 0, 0, 0);
	if (espera_sr(NDSR_RDDREQ, 1, 0.5, "RDDREQ (id)")) return -1;
	w[0] = nfc[NDDB / 4];
	w[1] = nfc[NDDB / 4];
	espera_ndrun(0.2);
	uint8_t *b = (uint8_t *)w;
	printf("ID del chip: %02x %02x %02x %02x %02x %02x (Hynix 256 MiB esperado: ad da ...)\n",
	       b[0], b[1], b[2], b[3], b[4], b[5]);
	return 0;
}

static void volcado(const char *t, const uint8_t *b, int n)
{
	printf("%s", t);
	for (int i = 0; i < n; i++)
		printf("%s%02x", i % 16 ? " " : "\n    ", b[i]);
	printf("\n");
}

static int borra_bloque(uint32_t off)
{
	uint32_t pag = off / PAGINA;
	if (prepara())
		return -1;
	envia(CMD_TYPE(T_ERASE) | ADDR_CYC(3) | DBC | CMD1(0x60) | CMD2(0xd0), pag & 0xffffff, 0, 0);
	if (espera_sr(NDSR_CMDD, 1, 0.5, "CMDD (borrado)"))
		return -1;
	if (espera_sr(NDSR_RDY, 1, 1.0, "RDY (borrado)"))
		return -1;
	return espera_ndrun(0.2);
}

static int graba_pagina(uint32_t pag, const uint8_t *buf)
{
	const uint32_t *p = (const uint32_t *)buf;
	if (prepara())
		return -1;
	envia(CMD_TYPE(T_WRITE) | LEN_OVRD | XTYPE(0) | ADDR_CYC(5) | CMD1(0x80) | CMD2(0x10) | DBC,
	      pag << 16, (pag >> 16) & 0xff, PAGINA + RESERVA);
	if (espera_sr(NDSR_WRDREQ, 1, 0.2, "WRDREQ"))
		return -1;
	for (unsigned i = 0; i < (PAGINA + RESERVA) / 4; i++)
		nfc[NDDB / 4] = p[i];
	if (espera_ndrun(0.5))
		return -1;
	if (espera_sr(NDSR_RDY, 1, 0.5, "RDY (grabación)"))
		return -1;
	return 0;
}

static void abre(void)
{
	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) { perror("/dev/mem"); exit(1); }
	volatile uint8_t *b = mmap(NULL, 0x100000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, REGS_FISICOS);
	if (b == MAP_FAILED) { perror("mmap"); exit(1); }
	nfc = (volatile uint32_t *)(b + NFC_OFF);
	clk = (volatile uint32_t *)(b + CLK_OFF);
	/* Patillas MPP41/42 = AD2/AD3 del bus de la NAND (función 1). Los núcleos con el uart1 de
	 * armada-370.dtsi las pasan a uart1 (función 2) y la NAND deja de leerse: devolverlas. */
	volatile uint32_t *mpp5 = (volatile uint32_t *)(b + 0x18014);
	if ((*mpp5 & 0x00000ff0u) != 0x00000110u) {
		uint32_t nuevo = (*mpp5 & ~0x00000ff0u) | 0x00000110u;
		printf("MPP41/42 no están en el bus de la NAND: 0x%08x -> 0x%08x\n", *mpp5, nuevo);
		*mpp5 = nuevo;
	}
	if (!(*clk & CLK_NAND)) {
		printf("Reloj de la NAND apagado: se enciende (0x%08x -> 0x%08x)\n", *clk, *clk | CLK_NAND);
		*clk = *clk | CLK_NAND;
		usleep(1000);
	}
	/* U-Boot puede haber dejado datos sin leer en la FIFO (NDSR.RDDREQ): vaciarla para no desalinear */
	int vaciados = 0;
	espera_ndrun(0.2);
	for (int i = 0; i < 200 && (rd(NDSR) & NDSR_RDDREQ); i++) {
		wr(NDSR, NDSR_RDDREQ);
		for (int k = 0; k < 8; k++)
			(void)nfc[NDDB / 4];
		vaciados += 32;
	}
	if (vaciados)
		printf("FIFO del controlador vaciada: %d bytes pendientes\n", vaciados);
	wr(NDSR, rd(NDSR));
	uint32_t ndcr = rd(NDCR);
	if (!(ndcr & NDCR_ECC_EN) || !(ndcr & NDCR_SPARE_EN) || (ndcr & NDCR_DMA_EN) ||
	    ((ndcr >> 24) & 3) != 1 || !(rd(NDECCCTRL) & 1)) {
		fprintf(stderr, "Configuración del controlador inesperada (NDCR=0x%08x NDECCCTRL=0x%08x): no sigo\n",
			ndcr, rd(NDECCCTRL));
		exit(1);
	}
}

static uint32_t num(const char *s) { return (uint32_t)strtoul(s, NULL, 0); }

/* Lee 'lon' bytes desde 'off' saltando bloques defectuosos (como nand read.e) */
static int leer(uint32_t off, uint32_t lon, uint8_t *dst, int detalle)
{
	uint8_t pg[PAGINA + RESERVA];
	uint32_t hecho = 0, pos = off;
	int vacias = 0, corr = 0;
	if (off % PAGINA) { fprintf(stderr, "El desplazamiento debe ser múltiplo de 2048\n"); return -1; }
	while (hecho < lon) {
		if (pos >= TOTAL) { fprintf(stderr, "Fuera de la NAND\n"); return -1; }
		if (es_defectuoso(pos)) {
			if (detalle) printf("  bloque 0x%08x defectuoso: se salta\n", pos);
			pos += BLOQUE;
			continue;
		}
		int bf, r = lee_pagina(pos / PAGINA, pg, &bf);
		if (r == -1) return -1;
		if (r == -2) { fprintf(stderr, "Error de ECC no corregible en 0x%08x\n", pos); return -1; }
		if (r == 1) vacias++;
		corr += bf;
		uint32_t n = lon - hecho < PAGINA ? lon - hecho : PAGINA;
		memcpy(dst + hecho, pg, n);
		hecho += n;
		pos += PAGINA;
	}
	if (detalle)
		printf("  leídos %u bytes (0x%08x-0x%08x), páginas vacías %d, bits corregidos %d\n",
		       lon, off, pos - 1, vacias, corr);
	return 0;
}

/* Graba 'lon' bytes en 'off' (múltiplo de bloque) saltando defectuosos; verifica cada bloque */
static int grabar(uint32_t off, const uint8_t *src, uint32_t lon)
{
	uint8_t pg[PAGINA + RESERVA], rb[PAGINA + RESERVA];
	uint32_t hecho = 0, pos = off;
	if (off % BLOQUE) { fprintf(stderr, "El desplazamiento debe ser múltiplo de 128 KiB\n"); return -1; }
	while (hecho < lon) {
		if (es_defectuoso(pos)) { printf("  bloque 0x%08x defectuoso: se salta\n", pos); pos += BLOQUE; continue; }
		if (!zona_escribible(pos, pos + BLOQUE)) {
			fprintf(stderr, "El bloque 0x%08x queda fuera de las zonas permitidas: no se graba\n", pos);
			return -1;
		}
		printf("  bloque 0x%08x: borrar", pos); fflush(stdout);
		if (borra_bloque(pos)) return -1;
		uint32_t ini = hecho;
		for (unsigned k = 0; k < PAG_BLOQUE && hecho < lon; k++) {
			uint32_t n = lon - hecho < PAGINA ? lon - hecho : PAGINA;
			memset(pg, 0xff, sizeof(pg));
			memcpy(pg, src + hecho, n);
			if (graba_pagina(pos / PAGINA + k, pg)) return -1;
			hecho += n;
		}
		printf(", grabar"); fflush(stdout);
		/* verificar el bloque */
		uint32_t v = ini;
		for (unsigned k = 0; k < PAG_BLOQUE && v < hecho; k++) {
			int bf, r = lee_pagina(pos / PAGINA + k, rb, &bf);
			uint32_t n = hecho - v < PAGINA ? hecho - v : PAGINA;
			if (r < 0 || memcmp(rb, src + v, n)) {
				int vacia = (r == 1);
				printf("\n*** La verificación ha FALLADO en la página 0x%08x (resultado %d%s). Me detengo.\n",
				       pos + k * PAGINA, r, vacia ? ", leída vacía" : "");
				return -1;
			}
			v += n;
		}
		printf(", verificado\n");
		pos += BLOQUE;
	}
	return 0;
}

int main(int argc, char **argv)
{
	if (argc < 2) goto uso;

	if (!strcmp(argv[1], "info")) {
		abre();
		printf("NDCR=0x%08x NDTR0=0x%08x NDTR1=0x%08x NDSR=0x%08x NDECCCTRL=0x%08x reloj=0x%08x\n",
		       rd(NDCR), rd(0x04), rd(0x0c), rd(NDSR), rd(NDECCCTRL), *clk);
		uint8_t pg[PAGINA + RESERVA];
		int bf, r = 0;
		for (int vez = 1; vez <= 3; vez++) {
			r = lee_pagina(0x500000 / PAGINA, pg, &bf);
			printf("Lectura %d de la 1.ª página de mtd1: resultado %d, bits corregidos %d, cabecera %02x %02x %02x %02x (uImage = 27 05 19 56), NDSR=0x%08x\n",
			       vez, r, bf, pg[0], pg[1], pg[2], pg[3], rd(NDSR));
			if (r == 0) printf("  Nombre: %.32s\n", pg + 32);
		}
		return r < 0;
	}

	if (!strcmp(argv[1], "reloj")) {   /* recarga el divisor del reloj de la NAND, como clk-corediv.c */
		abre();
		volatile uint32_t *ratio = clk + 2;   /* 0x18748 */
		printf("Antes: control=0x%08x divisor=0x%08x (NAND /%u)\n", *clk, *ratio, (*ratio >> 8) & 0x3f);
		*clk = *clk | (1u << 1);              /* forzar recarga para el reloj de la NAND */
		*clk = *clk | (1u << 8);              /* disparar la recarga */
		usleep(1000);
		*clk = *clk & ~(0xffu | (1u << 8));
		usleep(1000);
		printf("Después: control=0x%08x divisor=0x%08x\n", *clk, *ratio);
		return 0;
	}

	if (!strcmp(argv[1], "id")) {
		abre();
		if (identifica()) return 1;
		uint8_t pg[PAGINA + 64];
		int bf;
		for (int vez = 1; vez <= 2; vez++) {
			int r = lee_pagina(0x500000 / PAGINA, pg, &bf);
			printf("Tras el reset, lectura %d de 0x500000: resultado %d", vez, r);
			volcado("", pg, 16);
		}
		return 0;
	}

	if (!strcmp(argv[1], "pagina") && argc >= 3) {   /* solo lectura, diagnóstico */
		uint32_t off = num(argv[2]);
		uint8_t pg[PAGINA + 64];
		abre();
		int bf, r = lee_pagina(off / PAGINA, pg, &bf);
		printf("Con ECC: resultado %d, bits corregidos %d, NDSR=0x%08x", r, bf, rd(NDSR));
		volcado("", pg, 32);
		volcado("  reserva (2048..2079):", pg + PAGINA, 32);
		for (int ra = 1; ra >= 0; ra--) {
			memset(pg, 0, sizeof(pg));
			r = lee_cruda(off / PAGINA, pg, ra);
			printf("Sin ECC, direccionamiento %s: resultado %d", ra ? "normal" : "alternativo", r);
			volcado("", pg, 32);
			volcado("  2048..2111:", pg + PAGINA, 64);
		}
		return 0;
	}

	if (!strcmp(argv[1], "leer") && argc == 5) {
		uint32_t off = num(argv[2]), lon = num(argv[3]);
		uint8_t *b = malloc(lon);
		abre();
		if (!b || leer(off, lon, b, 1)) return 1;
		FILE *f = fopen(argv[4], "wb");
		if (!f || fwrite(b, 1, lon, f) != lon || fclose(f)) { perror(argv[4]); return 1; }
		printf("Guardado en %s\n", argv[4]);
		return 0;
	}

	if (!strcmp(argv[1], "grabar") && argc == 5 && !strcmp(argv[4], "SI-GRABAR")) {
		uint32_t off = num(argv[2]);
		FILE *f = fopen(argv[3], "rb");
		if (!f) { perror(argv[3]); return 1; }
		fseek(f, 0, SEEK_END); long lon = ftell(f); fseek(f, 0, SEEK_SET);
		uint8_t *b = malloc(lon);
		if (!b || fread(b, 1, lon, f) != (size_t)lon) { perror("lectura"); return 1; }
		fclose(f);
		uint32_t limite = off < 0xA00000u ? 0x400000u : (off < 0xF00000u ? 0x300000u : 0x40000u);
		if ((uint32_t)lon > limite) { fprintf(stderr, "El fichero (%ld bytes) supera lo que lee U-Boot (%u)\n", lon, limite); return 1; }
		if (!zona_escribible(off, off + lon)) { fprintf(stderr, "Zona no permitida\n"); return 1; }
		abre();
		printf("Grabando %s (%ld bytes) en 0x%08x\n", argv[3], lon, off);
		if (grabar(off, b, lon)) { printf("*** GRABACIÓN INCOMPLETA: NO reinicies; avisa antes de hacer nada.\n"); return 1; }
		printf("Grabación verificada.\n");
		return 0;
	}

	if (!strcmp(argv[1], "prueba") && argc == 3 && !strcmp(argv[2], "SI-GRABAR")) {
		uint32_t lon = 2 * BLOQUE - 1000;
		uint8_t *b = malloc(lon), *c = malloc(lon);
		srand(time(NULL));
		for (uint32_t i = 0; i < lon; i++) b[i] = rand();
		abre();
		printf("Prueba en la zona de image.cfs 0x02000000 (2 bloques)\n");
		if (grabar(0x2000000, b, lon)) return 1;
		if (leer(0x2000000, lon, c, 1) || memcmp(b, c, lon)) { printf("*** La relectura no coincide\n"); return 1; }
		printf("PRUEBA CORRECTA: borrar, grabar y leer funcionan.\n");
		return 0;
	}
uso:
	fprintf(stderr, "Uso:\n  nand340 info\n  nand340 leer DESPL LONGITUD FICHERO\n"
		"  nand340 grabar DESPL FICHERO SI-GRABAR\n  nand340 prueba SI-GRABAR\n  nand340 pagina DESPL   (diagnóstico)\n");
	return 2;
}
