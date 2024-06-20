/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2019 Western Digital Corporation or its affiliates.
 *
 * Authors:
 *   Anup Patel <anup.patel@wdc.com>
 */

#include <sbi/riscv_asm.h>
#include <sbi/riscv_encoding.h>
#include <sbi/riscv_elf.h>
#include <sbi/sbi_platform.h>
#include <sbi/sbi_scratch.h>
#include <sbi/sbi_trap.h>

#define BOOT_STATUS_LOTTERY_DONE	1
#define BOOT_STATUS_BOOT_HART_DONE	2

.macro	MOV_3R __d0, __s0, __d1, __s1, __d2, __s2
	add	\__d0, \__s0, zero
	add	\__d1, \__s1, zero
	add	\__d2, \__s2, zero
.endm

.macro	MOV_5R __d0, __s0, __d1, __s1, __d2, __s2, __d3, __s3, __d4, __s4
	add	\__d0, \__s0, zero
	add	\__d1, \__s1, zero
	add	\__d2, \__s2, zero
	add	\__d3, \__s3, zero
	add	\__d4, \__s4, zero
.endm

	.section .entry, "ax", %progbits
	.align 3
	.globl _start
	.globl _start_warm
_start:
	MOV_5R  x1,x0,x2,x0,x3,x0,x4,x0,x5,x0
	MOV_5R  x6,x0,x7,x0,x8,x0,x9,x0,x10,x0
	MOV_5R  x11,x0,x12,x0,x13,x0,x14,x0,x15,x0
	MOV_5R  x16,x0,x17,x0,x18,x0,x19,x0,x20,x0
	MOV_5R  x21,x0,x22,x0,x23,x0,x24,x0,x25,x0
	MOV_3R	x26,x0, x27,x0, x28,x0
	MOV_3R	x29,x0, x30,x0, x31,x0
	li a1,0x1020
	li a2,0x1000
	sub a1,a1,a2
#	lla a2,spike_dtb_hex
	add a1,a1,a2
	li a2,0

	/* Find preferred boot HART id */
	MOV_3R	s0, a0, s1, a1, s2, a2
	call	fw_boot_hart
	add	a6, a0, zero
	MOV_3R	a0, s0, a1, s1, a2, s2
	li	a7, -1
	beq	a6, a7, _try_lottery
	/* Jump to relocation wait loop if we are not boot hart */
	bne	a0, a6, _wait_for_boot_hart
_try_lottery:
	/* Jump to relocation wait loop if we don't get relocation lottery */
	lla	a6, _boot_status
	li	a7, BOOT_STATUS_LOTTERY_DONE
	amoswap.w a6, a7, (a6)	
	bnez	a6, _wait_for_boot_hart

	/* relocate the global table content */
	li	t0, FW_TEXT_START	/* link start */
	lla	t1, _fw_start		/* load start */
	sub	t2, t1, t0		/* load offset */
	lla	t0, __rel_dyn_start
	lla	t1, __rel_dyn_end
	beq	t0, t1, _relocate_done
2:
	REG_L	t5, REGBYTES(t0)	/* t5 <-- relocation info:type */
	li	t3, R_RISCV_RELATIVE	/* reloc type R_RISCV_RELATIVE */
	bne	t5, t3, 3f
	REG_L	t3, 0(t0)
	REG_L	t5, (REGBYTES * 2)(t0)	/* t5 <-- addend */
	add	t5, t5, t2
	add	t3, t3, t2
	REG_S	t5, 0(t3)		/* store runtime address to the GOT entry */

3:
	addi	t0, t0, (REGBYTES * 3)
	blt	t0, t1, 2b
_relocate_done:
	/* At this point we are running from link address */

	/* Reset all registers except ra, a0, a1, a2, a3 and a4 for boot HART */
	li	ra, 0
	call	_reset_regs

	/* Zero-out BSS */
	lla	s4, _bss_start
	lla	s5, _bss_end
_bss_zero:
	REG_S	zero, (s4)
	add	s4, s4, __SIZEOF_POINTER__
	blt	s4, s5, _bss_zero

	/* Setup temporary trap handler */
	lla	s4, _start_hang
	csrw	CSR_MTVEC, s4

	/* Setup temporary stack */
	lla	s4, _fw_end
	li	s5, (SBI_SCRATCH_SIZE * 2)
	add	sp, s4, s5

	/* Allow main firmware to save info */
	MOV_5R	s0, a0, s1, a1, s2, a2, s3, a3, s4, a4
	call	fw_save_info
	MOV_5R	a0, s0, a1, s1, a2, s2, a3, s3, a4, s4

#ifdef FW_FDT_PATH
	/* Override previous arg1 */
	lla	a1, fw_fdt_bin
#endif

	/*
	 * Initialize platform
	 * Note: The a0 to a4 registers passed to the
	 * firmware are parameters to this function.
	 */
	MOV_5R	s0, a0, s1, a1, s2, a2, s3, a3, s4, a4
	call	fw_platform_init
	add	t0, a0, zero
	MOV_5R	a0, s0, a1, s1, a2, s2, a3, s3, a4, s4
	add	a1, t0, zero

	/* Preload HART details
	 * s7 -> HART Count
	 * s8 -> HART Stack Size
	 * s9 -> Heap Size
	 * s10 -> Heap Offset
	 */
	lla	a4, platform
#if __riscv_xlen > 32
	lwu	s7, SBI_PLATFORM_HART_COUNT_OFFSET(a4)
	lwu	s8, SBI_PLATFORM_HART_STACK_SIZE_OFFSET(a4)
	lwu	s9, SBI_PLATFORM_HEAP_SIZE_OFFSET(a4)
#else
	lw	s7, SBI_PLATFORM_HART_COUNT_OFFSET(a4)
	lw	s8, SBI_PLATFORM_HART_STACK_SIZE_OFFSET(a4)
	lw	s9, SBI_PLATFORM_HEAP_SIZE_OFFSET(a4)
#endif

	/* Setup scratch space for all the HARTs*/
	lla	tp, _fw_end
	mul	a5, s7, s8
	add	tp, tp, a5
	/* Setup heap base address */
	lla	s10, _fw_start
	sub	s10, tp, s10
	add	tp, tp, s9
	/* Keep a copy of tp */
	add	t3, tp, zero
	/* Counter */
	li	t2, 1
	/* hartid 0 is mandated by ISA */
	li	t1, 0
_scratch_init:
	/*
	 * The following registers hold values that are computed before
	 * entering this block, and should remain unchanged.
	 *
	 * t3 -> the firmware end address
	 * s7 -> HART count
	 * s8 -> HART stack size
	 * s9 -> Heap Size
	 * s10 -> Heap Offset
	 */
	add	tp, t3, zero
	sub	tp, tp, s9
	mul	a5, s8, t1
	sub	tp, tp, a5
	li	a5, SBI_SCRATCH_SIZE
	sub	tp, tp, a5

	/* Initialize scratch space */
	/* Store fw_start and fw_size in scratch space */
	lla	a4, _fw_start
	sub	a5, t3, a4
	REG_S	a4, SBI_SCRATCH_FW_START_OFFSET(tp)
	REG_S	a5, SBI_SCRATCH_FW_SIZE_OFFSET(tp)

	/* Store R/W section's offset in scratch space */
	lla	a5, _fw_rw_start
	sub	a5, a5, a4
	REG_S	a5, SBI_SCRATCH_FW_RW_OFFSET(tp)

	/* Store fw_heap_offset and fw_heap_size in scratch space */
	REG_S	s10, SBI_SCRATCH_FW_HEAP_OFFSET(tp)
	REG_S	s9, SBI_SCRATCH_FW_HEAP_SIZE_OFFSET(tp)

	/* Store next arg1 in scratch space */
	MOV_3R	s0, a0, s1, a1, s2, a2
	call	fw_next_arg1
	REG_S	a0, SBI_SCRATCH_NEXT_ARG1_OFFSET(tp)
	MOV_3R	a0, s0, a1, s1, a2, s2
	/* Store next address in scratch space */
	MOV_3R	s0, a0, s1, a1, s2, a2
	call	fw_next_addr
	REG_S	a0, SBI_SCRATCH_NEXT_ADDR_OFFSET(tp)
	MOV_3R	a0, s0, a1, s1, a2, s2
	/* Store next mode in scratch space */
	MOV_3R	s0, a0, s1, a1, s2, a2
	call	fw_next_mode
	REG_S	a0, SBI_SCRATCH_NEXT_MODE_OFFSET(tp)
	MOV_3R	a0, s0, a1, s1, a2, s2
	/* Store warm_boot address in scratch space */
	lla	a4, _start_warm
	REG_S	a4, SBI_SCRATCH_WARMBOOT_ADDR_OFFSET(tp)
	/* Store platform address in scratch space */
	lla	a4, platform
	REG_S	a4, SBI_SCRATCH_PLATFORM_ADDR_OFFSET(tp)
	/* Store hartid-to-scratch function address in scratch space */
	lla	a4, _hartid_to_scratch
	REG_S	a4, SBI_SCRATCH_HARTID_TO_SCRATCH_OFFSET(tp)
	/* Clear trap_context and tmp0 in scratch space */
	REG_S	zero, SBI_SCRATCH_TRAP_CONTEXT_OFFSET(tp)
	REG_S	zero, SBI_SCRATCH_TMP0_OFFSET(tp)
	/* Store firmware options in scratch space */
	MOV_3R	s0, a0, s1, a1, s2, a2
#ifdef FW_OPTIONS
	li	a0, FW_OPTIONS
#else
	call	fw_options
#endif
	REG_S	a0, SBI_SCRATCH_OPTIONS_OFFSET(tp)
	MOV_3R	a0, s0, a1, s1, a2, s2
	/* Move to next scratch space */
	add	t1, t1, t2
	blt	t1, s7, _scratch_init

	/*
	 * Relocate Flatened Device Tree (FDT)
	 * source FDT address = previous arg1
	 * destination FDT address = next arg1
	 *
	 * Note: We will preserve a0 and a1 passed by
	 * previous booting stage.
	 */
	beqz	a1, _fdt_reloc_done
	/* Mask values in a4 */
	li	a4, 0xff
	/* t1 = destination FDT start address */
	MOV_3R	s0, a0, s1, a1, s2, a2
	call	fw_next_arg1
	add	t1, a0, zero
	MOV_3R	a0, s0, a1, s1, a2, s2
	beqz	t1, _fdt_reloc_done
	beq	t1, a1, _fdt_reloc_done
	/* t0 = source FDT start address */
	add	t0, a1, zero
	/* t2 = source FDT size in big-endian */
#if __riscv_xlen > 32
	lwu	t2, 4(t0)
#else
	lw	t2, 4(t0)
#endif
	/* t3 = bit[15:8] of FDT size */
	add	t3, t2, zero
	srli	t3, t3, 16
	and	t3, t3, a4
	slli	t3, t3, 8
	/* t4 = bit[23:16] of FDT size */
	add	t4, t2, zero
	srli	t4, t4, 8
	and	t4, t4, a4
	slli	t4, t4, 16
	/* t5 = bit[31:24] of FDT size */
	add	t5, t2, zero
	and	t5, t5, a4
	slli	t5, t5, 24
	/* t2 = bit[7:0] of FDT size */
	srli	t2, t2, 24
	and	t2, t2, a4
	/* t2 = FDT size in little-endian */
	or	t2, t2, t3
	or	t2, t2, t4
	or	t2, t2, t5
	/* t2 = destination FDT end address */
	add	t2, t1, t2
	/* FDT copy loop */
	ble	t2, t1, _fdt_reloc_done
_fdt_reloc_again:
	REG_L	t3, 0(t0)
	REG_S	t3, 0(t1)
	add	t0, t0, __SIZEOF_POINTER__
	add	t1, t1, __SIZEOF_POINTER__
	blt	t1, t2, _fdt_reloc_again
_fdt_reloc_done:

	/* mark boot hart done */
	li	t0, BOOT_STATUS_BOOT_HART_DONE
	lla	t1, _boot_status
	fence	rw, rw
	REG_S	t0, 0(t1)
	j	_start_warm

	/* waiting for boot hart to be done (_boot_status == 2) */
_wait_for_boot_hart:
	li	t0, BOOT_STATUS_BOOT_HART_DONE
	lla	t1, _boot_status
	REG_L	t1, 0(t1)
	/* Reduce the bus traffic so that boot hart may proceed faster */
	div	t2, t2, zero
	div	t2, t2, zero
	div	t2, t2, zero
	bne	t0, t1, _wait_for_boot_hart

_start_warm:
	/* Reset all registers except ra, a0, a1, a2, a3 and a4 for non-boot HART */
	li	ra, 0
	call	_reset_regs

	/* Disable all interrupts */
	csrw	CSR_MIE, zero

	/* Find HART count and HART stack size */
	lla	a4, platform
#if __riscv_xlen > 32
	lwu	s7, SBI_PLATFORM_HART_COUNT_OFFSET(a4)
	lwu	s8, SBI_PLATFORM_HART_STACK_SIZE_OFFSET(a4)
#else
	lw	s7, SBI_PLATFORM_HART_COUNT_OFFSET(a4)
	lw	s8, SBI_PLATFORM_HART_STACK_SIZE_OFFSET(a4)
#endif
	REG_L	s9, SBI_PLATFORM_HART_INDEX2ID_OFFSET(a4)

	/* Find HART id */
	csrr	s6, CSR_MHARTID

	/* Find HART index */
	beqz	s9, 3f
	li	a4, 0
1:
#if __riscv_xlen > 32
	lwu	a5, (s9)
#else
	lw	a5, (s9)
#endif
	beq	a5, s6, 2f
	add	s9, s9, 4
	add	a4, a4, 1
	blt	a4, s7, 1b
2:	add	s6, a4, zero
3:	bge	s6, s7, _start_hang

	/* Find the scratch space based on HART index */
	lla	tp, _fw_end
	mul	a5, s7, s8
	add	tp, tp, a5
	mul	a5, s8, s6
	sub	tp, tp, a5
	li	a5, SBI_SCRATCH_SIZE
	sub	tp, tp, a5

	/* update the mscratch */
	csrw	CSR_MSCRATCH, tp

	/* Setup stack */
	add	sp, tp, zero

	/* Setup trap handler */
	lla	a4, _trap_handler
	csrr	a5, CSR_MISA
	srli	a5, a5, ('H' - 'A')
	andi	a5, a5, 0x1
	beq	a5, zero, _skip_trap_handler_hyp
	lla	a4, _trap_handler_hyp
_skip_trap_handler_hyp:
	csrw	CSR_MTVEC, a4

	/* Initialize SBI runtime */
	csrr	a0, CSR_MSCRATCH
	call	sbi_init

	/* We don't expect to reach here hence just hang */
	j	_start_hang

	.data
	.align 3
spike_dtb_hex:
.dword 0x0202859300000297
.dword 0x0182b283f1402573
.dword 0x0000000000028067
.dword 0x0000000080000000
.dword 0x76060000edfe0dd0
.dword 0x2805000038000000
.dword 0x1100000028000000
.dword 0x0000000010000000
.dword 0xf00400004e010000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000001000000
.dword 0x0400000003000000
.dword 0x0200000000000000
.dword 0x0400000003000000
.dword 0x020000000f000000
.dword 0x1600000003000000
.dword 0x626263751b000000
.dword 0x656b6970732c7261
.dword 0x65642d657261622d
.dword 0x0300000000000076
.dword 0x2600000012000000
.dword 0x732c726162626375
.dword 0x7261622d656b6970
.dword 0x0100000000000065
.dword 0x00006e65736f6863
.dword 0x1600000003000000
.dword 0x636f732f2c000000
.dword 0x3035353631736e2f
.dword 0x3030303030303140
.dword 0x0300000000000030
.dword 0x3800000017000000
.dword 0x3d656c6f736e6f63
.dword 0x6165203053797474
.dword 0x00006e6f63796c72
.dword 0x0100000002000000
.dword 0x0000000073757063
.dword 0x0400000003000000
.dword 0x0100000000000000
.dword 0x0400000003000000
.dword 0x000000000f000000
.dword 0x0400000003000000
.dword 0x8096980041000000
.dword 0x4075706301000000
.dword 0x0300000000000030
.dword 0x5400000004000000
.dword 0x0300000000757063
.dword 0x6000000004000000
.dword 0x0300000000000000
.dword 0x6400000005000000
.dword 0x0000000079616b6f
.dword 0x0600000003000000
.dword 0x637369721b000000
.dword 0x0300000000000076
.dword 0x6b00000018000000
.dword 0x66616d6934367672
.dword 0x746e63697a5f6364
.dword 0x006d7068697a5f72
.dword 0x0b00000003000000
.dword 0x6373697275000000
.dword 0x0000373576732c76
.dword 0x0400000003000000
.dword 0x100000007e000000
.dword 0x0400000003000000
.dword 0x040000008f000000
.dword 0x0400000003000000
.dword 0x00ca9a3ba4000000
.dword 0x65746e6901000000
.dword 0x6f632d7470757272
.dword 0x72656c6c6f72746e
.dword 0x0300000000000000
.dword 0x0000000004000000
.dword 0x0300000002000000
.dword 0xb400000004000000
.dword 0x0300000001000000
.dword 0xc500000000000000
.dword 0x0f00000003000000
.dword 0x637369721b000000
.dword 0x6e692d7570632c76
.dword 0x0300000000006374
.dword 0xda00000004000000
.dword 0x0200000001000000
.dword 0x0200000002000000
.dword 0x6f6d656d01000000
.dword 0x3030303038407972
.dword 0x0300000000303030
.dword 0x5400000007000000
.dword 0x000079726f6d656d
.dword 0x1000000003000000
.dword 0x0000000060000000
.dword 0x0000000000000080
.dword 0x0200000000000080
.dword 0x00636f7301000000
.dword 0x0400000003000000
.dword 0x0200000000000000
.dword 0x0400000003000000
.dword 0x020000000f000000
.dword 0x2100000003000000
.dword 0x626263751b000000
.dword 0x656b6970732c7261
.dword 0x6f732d657261622d
.dword 0x656c706d69730063
.dword 0x000000007375622d
.dword 0x0000000003000000
.dword 0x01000000e2000000
.dword 0x303240746e696c63
.dword 0x0000003030303030
.dword 0x0d00000003000000
.dword 0x637369721b000000
.dword 0x30746e696c632c76
.dword 0x0300000000000000
.dword 0xe900000010000000
.dword 0x0300000001000000
.dword 0x0700000001000000
.dword 0x1000000003000000
.dword 0x0000000060000000
.dword 0x0000000000000002
.dword 0x0200000000000c00
.dword 0x63696c7001000000
.dword 0x3030303030306340
.dword 0x0300000000000000
.dword 0x1b0000000c000000
.dword 0x6c702c7663736972
.dword 0x0300000000306369
.dword 0x0000000004000000
.dword 0x0300000002000000
.dword 0xe900000010000000
.dword 0x0b00000001000000
.dword 0x0900000001000000
.dword 0x1000000003000000
.dword 0x0000000060000000
.dword 0x000000000000000c
.dword 0x0300000000000001
.dword 0xfd00000004000000
.dword 0x030000001f000000
.dword 0x0801000004000000
.dword 0x030000000f000000
.dword 0xb400000004000000
.dword 0x0300000001000000
.dword 0xc500000000000000
.dword 0x0400000003000000
.dword 0x02000000da000000
.dword 0x0100000002000000
.dword 0x403035353631736e
.dword 0x3030303030303031
.dword 0x0300000000000000
.dword 0x1b00000009000000
.dword 0x613035353631736e
.dword 0x0300000000000000
.dword 0xa400000004000000
.dword 0x0300000080969800
.dword 0x1b01000004000000
.dword 0x0300000002000000
.dword 0x2c01000004000000
.dword 0x0300000001000000
.dword 0x6000000010000000
.dword 0x0000001000000000
.dword 0x0001000000000000
.dword 0x0400000003000000
.dword 0x0000000037010000
.dword 0x0400000003000000
.dword 0x0100000041010000
.dword 0x0200000002000000
.dword 0x6669746801000000
.dword 0x0300000000000000
.dword 0x1b0000000a000000
.dword 0x666974682c626375
.dword 0x0200000000000030
.dword 0x0900000002000000
.dword 0x7373657264646123
.dword 0x2300736c6c65632d
.dword 0x6c65632d657a6973
.dword 0x61706d6f6300736c
.dword 0x6f6d00656c626974
.dword 0x6f647473006c6564
.dword 0x00687461702d7475
.dword 0x73677261746f6f62
.dword 0x736162656d697400
.dword 0x6575716572662d65
.dword 0x697665640079636e
.dword 0x00657079745f6563
.dword 0x7461747300676572
.dword 0x7663736972007375
.dword 0x756d6d006173692c
.dword 0x697200657079742d
.dword 0x72706d702c766373
.dword 0x7200736e6f696765
.dword 0x706d702c76637369
.dword 0x72616c756e617267
.dword 0x636f6c6300797469
.dword 0x6575716572662d6b
.dword 0x746e69230079636e
.dword 0x632d747075727265
.dword 0x746e6900736c6c65
.dword 0x632d747075727265
.dword 0x656c6c6f72746e6f
.dword 0x6c646e6168700072
.dword 0x7365676e61720065
.dword 0x75727265746e6900
.dword 0x657478652d737470
.dword 0x736972006465646e
.dword 0x007665646e2c7663
.dword 0x616d2c7663736972
.dword 0x69726f6972702d78
.dword 0x7265746e69007974
.dword 0x7261702d74707572
.dword 0x65746e6900746e65
.dword 0x7200737470757272
.dword 0x74666968732d6765
.dword 0x2d6f692d67657200
.dword 0x0000006874646977
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000
.dword 0x0000000000000000

_boot_status:
	RISCV_PTR	0

	.section .entry, "ax", %progbits
	.align 3
	.globl _hartid_to_scratch
_hartid_to_scratch:
	/*
	 * a0 -> HART ID (passed by caller)
	 * a1 -> HART Index (passed by caller)
	 * t0 -> HART Stack Size
	 * t1 -> HART Stack End
	 * t2 -> Temporary
	 */
	lla	t2, platform
#if __riscv_xlen > 32
	lwu	t0, SBI_PLATFORM_HART_STACK_SIZE_OFFSET(t2)
	lwu	t2, SBI_PLATFORM_HART_COUNT_OFFSET(t2)
#else
	lw	t0, SBI_PLATFORM_HART_STACK_SIZE_OFFSET(t2)
	lw	t2, SBI_PLATFORM_HART_COUNT_OFFSET(t2)
#endif
	sub	t2, t2, a1
	mul	t2, t2, t0
	lla	t1, _fw_end
	add	t1, t1, t2
	li	t2, SBI_SCRATCH_SIZE
	sub	a0, t1, t2
	ret

	.section .entry, "ax", %progbits
	.align 3
	.globl _start_hang
_start_hang:
	wfi
	j	_start_hang

	.section .entry, "ax", %progbits
	.align 3
	.weak fw_platform_init
fw_platform_init:
	add	a0, a1, zero
	ret

	/* Map implicit memcpy() added by compiler to sbi_memcpy() */
	.section .text
	.align 3
	.globl memcpy
memcpy:
	tail	sbi_memcpy

	/* Map implicit memset() added by compiler to sbi_memset() */
	.section .text
	.align 3
	.globl memset
memset:
	tail	sbi_memset

	/* Map implicit memmove() added by compiler to sbi_memmove() */
	.section .text
	.align 3
	.globl memmove
memmove:
	tail	sbi_memmove

	/* Map implicit memcmp() added by compiler to sbi_memcmp() */
	.section .text
	.align 3
	.globl memcmp
memcmp:
	tail	sbi_memcmp

.macro	TRAP_SAVE_AND_SETUP_SP_T0
	/* Swap TP and MSCRATCH */
	csrrw	tp, CSR_MSCRATCH, tp

	/* Save T0 in scratch space */
	REG_S	t0, SBI_SCRATCH_TMP0_OFFSET(tp)

	/*
	 * Set T0 to appropriate exception stack
	 *
	 * Came_From_M_Mode = ((MSTATUS.MPP < PRV_M) ? 1 : 0) - 1;
	 * Exception_Stack = TP ^ (Came_From_M_Mode & (SP ^ TP))
	 *
	 * Came_From_M_Mode = 0    ==>    Exception_Stack = TP
	 * Came_From_M_Mode = -1   ==>    Exception_Stack = SP
	 */
	csrr	t0, CSR_MSTATUS
	srl	t0, t0, MSTATUS_MPP_SHIFT
	and	t0, t0, PRV_M
	slti	t0, t0, PRV_M
	add	t0, t0, -1
	xor	sp, sp, tp
	and	t0, t0, sp
	xor	sp, sp, tp
	xor	t0, tp, t0

	/* Save original SP on exception stack */
	REG_S	sp, (SBI_TRAP_REGS_OFFSET(sp) - SBI_TRAP_CONTEXT_SIZE)(t0)

	/* Set SP to exception stack and make room for trap context */
	add	sp, t0, -(SBI_TRAP_CONTEXT_SIZE)

	/* Restore T0 from scratch space */
	REG_L	t0, SBI_SCRATCH_TMP0_OFFSET(tp)

	/* Save T0 on stack */
	REG_S	t0, SBI_TRAP_REGS_OFFSET(t0)(sp)

	/* Swap TP and MSCRATCH */
	csrrw	tp, CSR_MSCRATCH, tp
.endm

.macro	TRAP_SAVE_MEPC_MSTATUS have_mstatush
	/* Save MEPC and MSTATUS CSRs */
	csrr	t0, CSR_MEPC
	REG_S	t0, SBI_TRAP_REGS_OFFSET(mepc)(sp)
	csrr	t0, CSR_MSTATUS
	REG_S	t0, SBI_TRAP_REGS_OFFSET(mstatus)(sp)
	.if \have_mstatush
	csrr	t0, CSR_MSTATUSH
	REG_S	t0, SBI_TRAP_REGS_OFFSET(mstatusH)(sp)
	.else
	REG_S	zero, SBI_TRAP_REGS_OFFSET(mstatusH)(sp)
	.endif
.endm

.macro	TRAP_SAVE_GENERAL_REGS_EXCEPT_SP_T0
	/* Save all general regisers except SP and T0 */
	REG_S	zero, SBI_TRAP_REGS_OFFSET(zero)(sp)
	REG_S	ra, SBI_TRAP_REGS_OFFSET(ra)(sp)
	REG_S	gp, SBI_TRAP_REGS_OFFSET(gp)(sp)
	REG_S	tp, SBI_TRAP_REGS_OFFSET(tp)(sp)
	REG_S	t1, SBI_TRAP_REGS_OFFSET(t1)(sp)
	REG_S	t2, SBI_TRAP_REGS_OFFSET(t2)(sp)
	REG_S	s0, SBI_TRAP_REGS_OFFSET(s0)(sp)
	REG_S	s1, SBI_TRAP_REGS_OFFSET(s1)(sp)
	REG_S	a0, SBI_TRAP_REGS_OFFSET(a0)(sp)
	REG_S	a1, SBI_TRAP_REGS_OFFSET(a1)(sp)
	REG_S	a2, SBI_TRAP_REGS_OFFSET(a2)(sp)
	REG_S	a3, SBI_TRAP_REGS_OFFSET(a3)(sp)
	REG_S	a4, SBI_TRAP_REGS_OFFSET(a4)(sp)
	REG_S	a5, SBI_TRAP_REGS_OFFSET(a5)(sp)
	REG_S	a6, SBI_TRAP_REGS_OFFSET(a6)(sp)
	REG_S	a7, SBI_TRAP_REGS_OFFSET(a7)(sp)
	REG_S	s2, SBI_TRAP_REGS_OFFSET(s2)(sp)
	REG_S	s3, SBI_TRAP_REGS_OFFSET(s3)(sp)
	REG_S	s4, SBI_TRAP_REGS_OFFSET(s4)(sp)
	REG_S	s5, SBI_TRAP_REGS_OFFSET(s5)(sp)
	REG_S	s6, SBI_TRAP_REGS_OFFSET(s6)(sp)
	REG_S	s7, SBI_TRAP_REGS_OFFSET(s7)(sp)
	REG_S	s8, SBI_TRAP_REGS_OFFSET(s8)(sp)
	REG_S	s9, SBI_TRAP_REGS_OFFSET(s9)(sp)
	REG_S	s10, SBI_TRAP_REGS_OFFSET(s10)(sp)
	REG_S	s11, SBI_TRAP_REGS_OFFSET(s11)(sp)
	REG_S	t3, SBI_TRAP_REGS_OFFSET(t3)(sp)
	REG_S	t4, SBI_TRAP_REGS_OFFSET(t4)(sp)
	REG_S	t5, SBI_TRAP_REGS_OFFSET(t5)(sp)
	REG_S	t6, SBI_TRAP_REGS_OFFSET(t6)(sp)
.endm

.macro	TRAP_SAVE_INFO have_mstatush have_h_extension
	csrr	t0, CSR_MCAUSE
	REG_S	t0, (SBI_TRAP_REGS_SIZE + SBI_TRAP_INFO_OFFSET(cause))(sp)
	csrr	t0, CSR_MTVAL
	REG_S	t0, (SBI_TRAP_REGS_SIZE + SBI_TRAP_INFO_OFFSET(tval))(sp)
.if \have_h_extension
	csrr	t0, CSR_MTVAL2
	REG_S	t0, (SBI_TRAP_REGS_SIZE + SBI_TRAP_INFO_OFFSET(tval2))(sp)
	csrr	t0, CSR_MTINST
	REG_S	t0, (SBI_TRAP_REGS_SIZE + SBI_TRAP_INFO_OFFSET(tinst))(sp)
	.if \have_mstatush
	csrr	t0, CSR_MSTATUSH
	srli	t0, t0, MSTATUSH_GVA_SHIFT
	.else
	csrr	t0, CSR_MSTATUS
	srli	t0, t0, MSTATUS_GVA_SHIFT
	.endif
	and	t0, t0, 0x1
.else
	REG_S	zero, (SBI_TRAP_REGS_SIZE + SBI_TRAP_INFO_OFFSET(tval2))(sp)
	REG_S	zero, (SBI_TRAP_REGS_SIZE + SBI_TRAP_INFO_OFFSET(tinst))(sp)
	li	t0, 0
.endif
	REG_S	t0, (SBI_TRAP_REGS_SIZE + SBI_TRAP_INFO_OFFSET(gva))(sp)
.endm

.macro	TRAP_CALL_C_ROUTINE
	/* Call C routine */
	add	a0, sp, zero
	call	sbi_trap_handler
.endm

.macro	TRAP_RESTORE_GENERAL_REGS_EXCEPT_A0_T0
	/* Restore all general regisers except A0 and T0 */
	REG_L	ra, SBI_TRAP_REGS_OFFSET(ra)(a0)
	REG_L	sp, SBI_TRAP_REGS_OFFSET(sp)(a0)
	REG_L	gp, SBI_TRAP_REGS_OFFSET(gp)(a0)
	REG_L	tp, SBI_TRAP_REGS_OFFSET(tp)(a0)
	REG_L	t1, SBI_TRAP_REGS_OFFSET(t1)(a0)
	REG_L	t2, SBI_TRAP_REGS_OFFSET(t2)(a0)
	REG_L	s0, SBI_TRAP_REGS_OFFSET(s0)(a0)
	REG_L	s1, SBI_TRAP_REGS_OFFSET(s1)(a0)
	REG_L	a1, SBI_TRAP_REGS_OFFSET(a1)(a0)
	REG_L	a2, SBI_TRAP_REGS_OFFSET(a2)(a0)
	REG_L	a3, SBI_TRAP_REGS_OFFSET(a3)(a0)
	REG_L	a4, SBI_TRAP_REGS_OFFSET(a4)(a0)
	REG_L	a5, SBI_TRAP_REGS_OFFSET(a5)(a0)
	REG_L	a6, SBI_TRAP_REGS_OFFSET(a6)(a0)
	REG_L	a7, SBI_TRAP_REGS_OFFSET(a7)(a0)
	REG_L	s2, SBI_TRAP_REGS_OFFSET(s2)(a0)
	REG_L	s3, SBI_TRAP_REGS_OFFSET(s3)(a0)
	REG_L	s4, SBI_TRAP_REGS_OFFSET(s4)(a0)
	REG_L	s5, SBI_TRAP_REGS_OFFSET(s5)(a0)
	REG_L	s6, SBI_TRAP_REGS_OFFSET(s6)(a0)
	REG_L	s7, SBI_TRAP_REGS_OFFSET(s7)(a0)
	REG_L	s8, SBI_TRAP_REGS_OFFSET(s8)(a0)
	REG_L	s9, SBI_TRAP_REGS_OFFSET(s9)(a0)
	REG_L	s10, SBI_TRAP_REGS_OFFSET(s10)(a0)
	REG_L	s11, SBI_TRAP_REGS_OFFSET(s11)(a0)
	REG_L	t3, SBI_TRAP_REGS_OFFSET(t3)(a0)
	REG_L	t4, SBI_TRAP_REGS_OFFSET(t4)(a0)
	REG_L	t5, SBI_TRAP_REGS_OFFSET(t5)(a0)
	REG_L	t6, SBI_TRAP_REGS_OFFSET(t6)(a0)
.endm

.macro	TRAP_RESTORE_MEPC_MSTATUS have_mstatush
	/* Restore MEPC and MSTATUS CSRs */
	REG_L	t0, SBI_TRAP_REGS_OFFSET(mepc)(a0)
	csrw	CSR_MEPC, t0
	REG_L	t0, SBI_TRAP_REGS_OFFSET(mstatus)(a0)
	csrw	CSR_MSTATUS, t0
	.if \have_mstatush
	REG_L	t0, SBI_TRAP_REGS_OFFSET(mstatusH)(a0)
	csrw	CSR_MSTATUSH, t0
	.endif
.endm

.macro TRAP_RESTORE_A0_T0
	/* Restore T0 */
	REG_L	t0, SBI_TRAP_REGS_OFFSET(t0)(a0)

	/* Restore A0 */
	REG_L	a0, SBI_TRAP_REGS_OFFSET(a0)(a0)
.endm

	.section .entry, "ax", %progbits
	.align 3
	.globl _trap_handler
_trap_handler:
	TRAP_SAVE_AND_SETUP_SP_T0

	TRAP_SAVE_MEPC_MSTATUS 0

	TRAP_SAVE_GENERAL_REGS_EXCEPT_SP_T0

	TRAP_SAVE_INFO 0 0

	TRAP_CALL_C_ROUTINE

	TRAP_RESTORE_GENERAL_REGS_EXCEPT_A0_T0

	TRAP_RESTORE_MEPC_MSTATUS 0

	TRAP_RESTORE_A0_T0

	mret

	.section .entry, "ax", %progbits
	.align 3
	.globl _trap_handler_hyp
_trap_handler_hyp:
	TRAP_SAVE_AND_SETUP_SP_T0

#if __riscv_xlen == 32
	TRAP_SAVE_MEPC_MSTATUS 1
#else
	TRAP_SAVE_MEPC_MSTATUS 0
#endif

	TRAP_SAVE_GENERAL_REGS_EXCEPT_SP_T0

#if __riscv_xlen == 32
	TRAP_SAVE_INFO 1 1
#else
	TRAP_SAVE_INFO 0 1
#endif

	TRAP_CALL_C_ROUTINE

	TRAP_RESTORE_GENERAL_REGS_EXCEPT_A0_T0

#if __riscv_xlen == 32
	TRAP_RESTORE_MEPC_MSTATUS 1
#else
	TRAP_RESTORE_MEPC_MSTATUS 0
#endif

	TRAP_RESTORE_A0_T0

	mret

	.section .entry, "ax", %progbits
	.align 3
	.globl _reset_regs
_reset_regs:

	/* flush the instruction cache */
	fence.i
	/* Reset all registers except ra, a0, a1, a2, a3 and a4 */
	li sp, 0
	li gp, 0
	li tp, 0
	li t0, 0
	li t1, 0
	li t2, 0
	li s0, 0
	li s1, 0
	li a5, 0
	li a6, 0
	li a7, 0
	li s2, 0
	li s3, 0
	li s4, 0
	li s5, 0
	li s6, 0
	li s7, 0
	li s8, 0
	li s9, 0
	li s10, 0
	li s11, 0
	li t3, 0
	li t4, 0
	li t5, 0
	li t6, 0
	csrw CSR_MSCRATCH, 0

	ret

#ifdef FW_FDT_PATH
	.section .rodata
	.align 4
	.globl fw_fdt_bin
fw_fdt_bin:
	.incbin FW_FDT_PATH
#ifdef FW_FDT_PADDING
	.fill FW_FDT_PADDING, 1, 0
#endif
#endif
