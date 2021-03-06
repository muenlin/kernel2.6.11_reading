/*
 *  linux/arch/arm/kernel/entry-armv.S
 *
 *  Copyright (C) 1996,1997,1998 Russell King.
 *  ARM700 fix by Matthew Godbolt (linux-user@willothewisp.demon.co.uk)
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 *
 *  Low-level vector interface routines
 *
 *  Note:  there is a StrongARM bug in the STMIA rn, {regs}^ instruction that causes
 *  it to save wrong values...  Be aware!
 */
#include <linux/config.h>
#include <linux/init.h>

#include <asm/thread_info.h>
#include <asm/glue.h>
#include <asm/ptrace.h>
#include <asm/vfpmacros.h>

#include "entry-header.S"

/*
 * Invalid mode handlers
 */
	.macro	inv_entry, sym, reason
	sub	sp, sp, #S_FRAME_SIZE		@ Allocate frame size in one go
	stmia	sp, {r0 - lr}			@ Save XXX r0 - lr
	ldr	r4, .LC\sym
	mov	r1, #\reason
	.endm

__pabt_invalid:
	inv_entry abt, BAD_PREFETCH
	b	1f

__dabt_invalid:
	inv_entry abt, BAD_DATA
	b	1f

__irq_invalid:
	inv_entry irq, BAD_IRQ
	b	1f

__und_invalid:
	inv_entry und, BAD_UNDEFINSTR

1:	zero_fp
	ldmia	r4, {r5 - r7}			@ Get XXX pc, cpsr, old_r0
	add	r4, sp, #S_PC
	stmia	r4, {r5 - r7}			@ Save XXX pc, cpsr, old_r0
	mov	r0, sp
	and	r2, r6, #31			@ int mode
	b	bad_mode

/*
 * SVC mode handlers
 */
	.macro	svc_entry, sym
	sub	sp, sp, #S_FRAME_SIZE
	stmia	sp, {r0 - r12}			@ save r0 - r12
	ldr	r2, .LC\sym
	add	r0, sp, #S_FRAME_SIZE
	ldmia	r2, {r2 - r4}			@ get pc, cpsr
	add	r5, sp, #S_SP
	mov	r1, lr

	@
	@ We are now ready to fill in the remaining blanks on the stack:
	@
	@  r0 - sp_svc
	@  r1 - lr_svc
	@  r2 - lr_<exception>, already fixed up for correct return/restart
	@  r3 - spsr_<exception>
	@  r4 - orig_r0 (see pt_regs definition in ptrace.h)
	@
	stmia	r5, {r0 - r4}
	.endm

	.align	5
__dabt_svc:
	svc_entry abt

	@
	@ get ready to re-enable interrupts if appropriate
	@
	mrs	r9, cpsr
	tst	r3, #PSR_I_BIT
	biceq	r9, r9, #PSR_I_BIT

	@
	@ Call the processor-specific abort handler:
	@
	@  r2 - aborted context pc
	@  r3 - aborted context cpsr
	@
	@ The abort handler must return the aborted address in r0, and
	@ the fault status register in r1.  r9 must be preserved.
	@
#ifdef MULTI_ABORT
	ldr	r4, .LCprocfns
	mov	lr, pc
	ldr	pc, [r4]
#else
	bl	CPU_ABORT_HANDLER
#endif

	@
	@ set desired IRQ state, then call main handler
	@
	msr	cpsr_c, r9
	mov	r2, sp
	bl	do_DataAbort

	@
	@ IRQs off again before pulling preserved data off the stack
	@
	disable_irq r0

	@
	@ restore SPSR and restart the instruction
	@
	ldr	r0, [sp, #S_PSR]
	msr	spsr_cxsf, r0
	ldmia	sp, {r0 - pc}^			@ load r0 - pc, cpsr

	.align	5
__irq_svc:
	svc_entry irq
#ifdef CONFIG_PREEMPT
	get_thread_info r8
	ldr	r9, [r8, #TI_PREEMPT]		@ get preempt count
	add	r7, r9, #1			@ increment it
	str	r7, [r8, #TI_PREEMPT]
#endif
1:	get_irqnr_and_base r0, r6, r5, lr
	movne	r1, sp
	@
	@ routine called with r0 = irq number, r1 = struct pt_regs *
	@
	adrne	lr, 1b
	bne	asm_do_IRQ
#ifdef CONFIG_PREEMPT
	ldr	r0, [r8, #TI_FLAGS]		@ get flags
	tst	r0, #_TIF_NEED_RESCHED
	blne	svc_preempt
preempt_return:
	ldr	r0, [r8, #TI_PREEMPT]		@ read preempt value
	teq	r0, r7
	str	r9, [r8, #TI_PREEMPT]		@ restore preempt count
	strne	r0, [r0, -r0]			@ bug()
#endif
	ldr	r0, [sp, #S_PSR]		@ irqs are already disabled
	msr	spsr_cxsf, r0
	ldmia	sp, {r0 - pc}^			@ load r0 - pc, cpsr

	.ltorg

#ifdef CONFIG_PREEMPT
svc_preempt:
	teq	r9, #0				@ was preempt count = 0
	ldreq	r6, .LCirq_stat
	movne	pc, lr				@ no
	ldr	r0, [r6, #4]			@ local_irq_count
	ldr	r1, [r6, #8]			@ local_bh_count
	adds	r0, r0, r1
	movne	pc, lr
	mov	r7, #0				@ preempt_schedule_irq
	str	r7, [r8, #TI_PREEMPT]		@ expects preempt_count == 0
1:	bl	preempt_schedule_irq		@ irq en/disable is done inside
	ldr	r0, [r8, #TI_FLAGS]		@ get new tasks TI_FLAGS
	tst	r0, #_TIF_NEED_RESCHED
	beq	preempt_return			@ go again
	b	1b
#endif

	.align	5
__und_svc:
	svc_entry und

	@
	@ call emulation code, which returns using r9 if it has emulated
	@ the instruction, or the more conventional lr if we are to treat
	@ this as a real undefined instruction
	@
	@  r0 - instruction
	@
	ldr	r0, [r2, #-4]
	adr	r9, 1f
	bl	call_fpe

	mov	r0, sp				@ struct pt_regs *regs
	bl	do_undefinstr

	@
	@ IRQs off again before pulling preserved data off the stack
	@
1:	disable_irq r0

	@
	@ restore SPSR and restart the instruction
	@
	ldr	lr, [sp, #S_PSR]		@ Get SVC cpsr
	msr	spsr_cxsf, lr
	ldmia	sp, {r0 - pc}^			@ Restore SVC registers

	.align	5
__pabt_svc:
	svc_entry abt

	@
	@ re-enable interrupts if appropriate
	@
	mrs	r9, cpsr
	tst	r3, #PSR_I_BIT
	biceq	r9, r9, #PSR_I_BIT
	msr	cpsr_c, r9

	@
	@ set args, then call main handler
	@
	@  r0 - address of faulting instruction
	@  r1 - pointer to registers on stack
	@
	mov	r0, r2				@ address (pc)
	mov	r1, sp				@ regs
	bl	do_PrefetchAbort		@ call abort handler

	@
	@ IRQs off again before pulling preserved data off the stack
	@
	disable_irq r0

	@
	@ restore SPSR and restart the instruction
	@
	ldr	r0, [sp, #S_PSR]
	msr	spsr_cxsf, r0
	ldmia	sp, {r0 - pc}^			@ load r0 - pc, cpsr

	.align	5
.LCirq:
	.word	__temp_irq
.LCund:
	.word	__temp_und
.LCabt:
	.word	__temp_abt
#ifdef MULTI_ABORT
.LCprocfns:
	.word	processor
#endif
.LCfp:
	.word	fp_enter
#ifdef CONFIG_PREEMPT
.LCirq_stat:
	.word	irq_stat
#endif

/*
 * User mode handlers
 */
	.macro	usr_entry, sym
	sub	sp, sp, #S_FRAME_SIZE		@ Allocate frame size in one go
	stmia	sp, {r0 - r12}			@ save r0 - r12
	ldr	r7, .LC\sym
	add	r5, sp, #S_PC
	ldmia	r7, {r2 - r4}			@ Get USR pc, cpsr

	@
	@ We are now ready to fill in the remaining blanks on the stack:
	@
	@  r2 - lr_<exception>, already fixed up for correct return/restart
	@  r3 - spsr_<exception>
	@  r4 - orig_r0 (see pt_regs definition in ptrace.h)
	@
	@ Also, separately save sp_usr and lr_usr
	@
	stmia	r5, {r2 - r4}
	stmdb	r5, {sp, lr}^
	.endm

	.align	5
__dabt_usr:
	usr_entry abt
	alignment_trap r7, r0, __temp_abt
	zero_fp

	@
	@ Call the processor-specific abort handler:
	@
	@  r2 - aborted context pc
	@  r3 - aborted context cpsr
	@
	@ The abort handler must return the aborted address in r0, and
	@ the fault status register in r1.
	@
#ifdef MULTI_ABORT
	ldr	r4, .LCprocfns
	mov	lr, pc
	ldr	pc, [r4]
#else
	bl	CPU_ABORT_HANDLER
#endif

	@
	@ IRQs on, then call the main handler
	@
	enable_irq r2
	mov	r2, sp
	adr	lr, ret_from_exception
	b	do_DataAbort

	.align	5
__irq_usr:
	usr_entry irq
	alignment_trap r7, r0, __temp_irq
	zero_fp
#ifdef CONFIG_PREEMPT
	get_thread_info r8
	ldr	r9, [r8, #TI_PREEMPT]		@ get preempt count
	add	r7, r9, #1			@ increment it
	str	r7, [r8, #TI_PREEMPT]
#endif
1:	get_irqnr_and_base r0, r6, r5, lr
	movne	r1, sp
	adrne	lr, 1b
	@
	@ routine called with r0 = irq number, r1 = struct pt_regs *
	@
	bne	asm_do_IRQ
#ifdef CONFIG_PREEMPT
	ldr	r0, [r8, #TI_PREEMPT]
	teq	r0, r7
	str	r9, [r8, #TI_PREEMPT]
	strne	r0, [r0, -r0]
	mov	tsk, r8
#else
	get_thread_info tsk
#endif
	mov	why, #0
	b	ret_to_user

	.ltorg

	.align	5
__und_usr:
	usr_entry und
	alignment_trap r7, r0, __temp_und
	zero_fp
	tst	r3, #PSR_T_BIT			@ Thumb mode?
	bne	fpundefinstr			@ ignore FP
	sub	r4, r2, #4

	@
	@ fall through to the emulation code, which returns using r9 if
	@ it has emulated the instruction, or the more conventional lr
	@ if we are to treat this as a real undefined instruction
	@
	@  r0 - instruction
	@
1:	ldrt	r0, [r4]
	adr	r9, ret_from_exception
	adr	lr, fpundefinstr
	@
	@ fallthrough to call_fpe
	@

/*
 * The out of line fixup for the ldrt above.
 */
	.section .fixup, "ax"
2:	mov	pc, r9
	.previous
	.section __ex_table,"a"
	.long	1b, 2b
	.previous

/*
 * Check whether the instruction is a co-processor instruction.
 * If yes, we need to call the relevant co-processor handler.
 *
 * Note that we don't do a full check here for the co-processor
 * instructions; all instructions with bit 27 set are well
 * defined.  The only instructions that should fault are the
 * co-processor instructions.  However, we have to watch out
 * for the ARM6/ARM7 SWI bug.
 *
 * Emulators may wish to make use of the following registers:
 *  r0  = instruction opcode.
 *  r2  = PC+4
 *  r10 = this threads thread_info structure.
 */
call_fpe:
	tst	r0, #0x08000000			@ only CDP/CPRT/LDC/STC have bit 27
#if defined(CONFIG_CPU_ARM610) || defined(CONFIG_CPU_ARM710)
	and	r8, r0, #0x0f000000		@ mask out op-code bits
	teqne	r8, #0x0f000000			@ SWI (ARM6/7 bug)?
#endif
	moveq	pc, lr
	get_thread_info r10			@ get current thread
	and	r8, r0, #0x00000f00		@ mask out CP number
	mov	r7, #1
	add	r6, r10, #TI_USED_CP
	strb	r7, [r6, r8, lsr #8]		@ set appropriate used_cp[]
#ifdef CONFIG_IWMMXT
	@ Test if we need to give access to iWMMXt coprocessors
	ldr	r5, [r10, #TI_FLAGS]
	rsbs	r7, r8, #(1 << 8)		@ CP 0 or 1 only
	movcss	r7, r5, lsr #(TIF_USING_IWMMXT + 1)
	bcs	iwmmxt_task_enable
#endif
	enable_irq r7
	add	pc, pc, r8, lsr #6
	mov	r0, r0

	mov	pc, lr				@ CP#0
	b	do_fpe				@ CP#1 (FPE)
	b	do_fpe				@ CP#2 (FPE)
	mov	pc, lr				@ CP#3
	mov	pc, lr				@ CP#4
	mov	pc, lr				@ CP#5
	mov	pc, lr				@ CP#6
	mov	pc, lr				@ CP#7
	mov	pc, lr				@ CP#8
	mov	pc, lr				@ CP#9
#ifdef CONFIG_VFP
	b	do_vfp				@ CP#10 (VFP)
	b	do_vfp				@ CP#11 (VFP)
#else
	mov	pc, lr				@ CP#10 (VFP)
	mov	pc, lr				@ CP#11 (VFP)
#endif
	mov	pc, lr				@ CP#12
	mov	pc, lr				@ CP#13
	mov	pc, lr				@ CP#14 (Debug)
	mov	pc, lr				@ CP#15 (Control)

do_fpe:
	ldr	r4, .LCfp
	add	r10, r10, #TI_FPSTATE		@ r10 = workspace
	ldr	pc, [r4]			@ Call FP module USR entry point

/*
 * The FP module is called with these registers set:
 *  r0  = instruction
 *  r2  = PC+4
 *  r9  = normal "successful" return address
 *  r10 = FP workspace
 *  lr  = unrecognised FP instruction return address
 */

	.data
ENTRY(fp_enter)
	.word	fpundefinstr
	.text

fpundefinstr:
	mov	r0, sp
	adr	lr, ret_from_exception
	b	do_undefinstr

	.align	5
__pabt_usr:
	usr_entry abt
	alignment_trap r7, r0, __temp_abt
	zero_fp
	enable_irq r0				@ Enable interrupts
	mov	r0, r2				@ address (pc)
	mov	r1, sp				@ regs
	bl	do_PrefetchAbort		@ call abort handler
	/* fall through */
/*
 * This is the return code to user mode for abort handlers
 */
ENTRY(ret_from_exception)
	get_thread_info tsk
	mov	why, #0
	b	ret_to_user

//http://blog.sina.com.cn/s/blog_d9889c5b0101e7x6.html
//@ r0 = previous task_struct, r1 = previous thread_info, r2 = next thread_info
//@
//ENTRY(__switch_to)
//@ thread_info + TI_CPU_SAVE hold saved cpu context, registers value is stored
//@ now ip hold the address of the context of previous process 
//add ip, r1, #TI_CPU_SAVE
//@ now r3 hold TP value of next process 
//ldr r3, [r2, #TI_TP_VALUE]
//@ store current regs to prev thread_info 
//stmia ip!, {r4 - sl, fp, sp, lr} @ Store most regs on
//@ store CPU_DOMAIN of next to r6 
//ldr r6, [r2, #TI_CPU_DOMAIN]
//@ set tp value and domain to cp15 
//mcr p15, 0, r3, c13, c0, 3 @ yes, set TLS register
//mcr p15, 0, r6, c3, c0, 0 @ Set domain register
//@ now r4 hold the address of the next context 
//add r4, r2, #TI_CPU_SAVE
//@ put next context to registers 
//ldmia r4, {r4 - sl, fp, sp, pc} @ Load all regs saved previously
//ENDPROC(__switch_to) 	
/*
 * Register switch for ARMv3 and ARMv4 processors
 * r0 = previous task_struct, r1 = previous thread_info, r2 = next thread_info
 * previous and next are guaranteed not to be the same.
 */
 
ENTRY(__switch_to)
	add	ip, r1, #TI_CPU_SAVE
	ldr	r3, [r2, #TI_TP_VALUE]
	stmia	ip!, {r4 - sl, fp, sp, lr}	@ Store most regs on stack
	ldr	r6, [r2, #TI_CPU_DOMAIN]!
#if defined(CONFIG_CPU_XSCALE) && !defined(CONFIG_IWMMXT)
	mra	r4, r5, acc0
	stmia   ip, {r4, r5}
#endif
	mov	r4, #0xffff0fff
	str	r3, [r4, #-3]			@ Set TLS ptr
	mcr	p15, 0, r6, c3, c0, 0		@ Set domain register
#ifdef CONFIG_VFP
	@ Always disable VFP so we can lazily save/restore the old
	@ state. This occurs in the context of the previous thread.
	VFPFMRX	r4, FPEXC
	bic	r4, r4, #FPEXC_ENABLE
	VFPFMXR	FPEXC, r4
#endif
#if defined(CONFIG_IWMMXT)
	bl	iwmmxt_task_switch
#elif defined(CONFIG_CPU_XSCALE)
	add	r4, r2, #40			@ cpu_context_save->extra
	ldmib	r4, {r4, r5}
	mar	acc0, r4, r5
#endif
	//感觉r2的值不对，参考2.6.24版本的内核把
	ldmib	r2, {r4 - sl, fp, sp, pc}	@ Load all regs saved previously

	__INIT
/*
 * Vector stubs.
 *
 * This code is copied to 0x200 or 0xffff0200 so we can use branches in the
 * vectors, rather than ldr's.
 *
 * Common stub entry macro:
 *   Enter in IRQ mode, spsr = SVC/USR CPSR, lr = SVC/USR PC
 */
	.macro	vector_stub, name, sym, correction=0
	.align	5

vector_\name:
	ldr	r13, .LCs\sym
	.if \correction
	sub	lr, lr, #\correction
	.endif
	str	lr, [r13]			@ save lr_IRQ
	mrs	lr, spsr
	str	lr, [r13, #4]			@ save spsr_IRQ
	@
	@ now branch to the relevant MODE handling routine
	@
	mrs	r13, cpsr
	bic	r13, r13, #MODE_MASK
	orr	r13, r13, #MODE_SVC
	msr	spsr_cxsf, r13			@ switch to SVC_32 mode

	and	lr, lr, #15
	ldr	lr, [pc, lr, lsl #2]
	movs	pc, lr				@ Changes mode and branches
	.endm

__stubs_start:
/*
 * Interrupt dispatcher
 */
	vector_stub	irq, irq, 4

	.long	__irq_usr			@  0  (USR_26 / USR_32)
	.long	__irq_invalid			@  1  (FIQ_26 / FIQ_32)
	.long	__irq_invalid			@  2  (IRQ_26 / IRQ_32)
	.long	__irq_svc			@  3  (SVC_26 / SVC_32)
	.long	__irq_invalid			@  4
	.long	__irq_invalid			@  5
	.long	__irq_invalid			@  6
	.long	__irq_invalid			@  7
	.long	__irq_invalid			@  8
	.long	__irq_invalid			@  9
	.long	__irq_invalid			@  a
	.long	__irq_invalid			@  b
	.long	__irq_invalid			@  c
	.long	__irq_invalid			@  d
	.long	__irq_invalid			@  e
	.long	__irq_invalid			@  f

/*
 * Data abort dispatcher
 * Enter in ABT mode, spsr = USR CPSR, lr = USR PC
 */
	vector_stub	dabt, abt, 8

	.long	__dabt_usr			@  0  (USR_26 / USR_32)
	.long	__dabt_invalid			@  1  (FIQ_26 / FIQ_32)
	.long	__dabt_invalid			@  2  (IRQ_26 / IRQ_32)
	.long	__dabt_svc			@  3  (SVC_26 / SVC_32)
	.long	__dabt_invalid			@  4
	.long	__dabt_invalid			@  5
	.long	__dabt_invalid			@  6
	.long	__dabt_invalid			@  7
	.long	__dabt_invalid			@  8
	.long	__dabt_invalid			@  9
	.long	__dabt_invalid			@  a
	.long	__dabt_invalid			@  b
	.long	__dabt_invalid			@  c
	.long	__dabt_invalid			@  d
	.long	__dabt_invalid			@  e
	.long	__dabt_invalid			@  f

/*
 * Prefetch abort dispatcher
 * Enter in ABT mode, spsr = USR CPSR, lr = USR PC
 */
	vector_stub	pabt, abt, 4

	.long	__pabt_usr			@  0 (USR_26 / USR_32)
	.long	__pabt_invalid			@  1 (FIQ_26 / FIQ_32)
	.long	__pabt_invalid			@  2 (IRQ_26 / IRQ_32)
	.long	__pabt_svc			@  3 (SVC_26 / SVC_32)
	.long	__pabt_invalid			@  4
	.long	__pabt_invalid			@  5
	.long	__pabt_invalid			@  6
	.long	__pabt_invalid			@  7
	.long	__pabt_invalid			@  8
	.long	__pabt_invalid			@  9
	.long	__pabt_invalid			@  a
	.long	__pabt_invalid			@  b
	.long	__pabt_invalid			@  c
	.long	__pabt_invalid			@  d
	.long	__pabt_invalid			@  e
	.long	__pabt_invalid			@  f

/*
 * Undef instr entry dispatcher
 * Enter in UND mode, spsr = SVC/USR CPSR, lr = SVC/USR PC
 */
	vector_stub	und, und

	.long	__und_usr			@  0 (USR_26 / USR_32)
	.long	__und_invalid			@  1 (FIQ_26 / FIQ_32)
	.long	__und_invalid			@  2 (IRQ_26 / IRQ_32)
	.long	__und_svc			@  3 (SVC_26 / SVC_32)
	.long	__und_invalid			@  4
	.long	__und_invalid			@  5
	.long	__und_invalid			@  6
	.long	__und_invalid			@  7
	.long	__und_invalid			@  8
	.long	__und_invalid			@  9
	.long	__und_invalid			@  a
	.long	__und_invalid			@  b
	.long	__und_invalid			@  c
	.long	__und_invalid			@  d
	.long	__und_invalid			@  e
	.long	__und_invalid			@  f

	.align	5

/*=============================================================================
 * Undefined FIQs
 *-----------------------------------------------------------------------------
 * Enter in FIQ mode, spsr = ANY CPSR, lr = ANY PC
 * MUST PRESERVE SVC SPSR, but need to switch to SVC mode to show our msg.
 * Basically to switch modes, we *HAVE* to clobber one register...  brain
 * damage alert!  I don't think that we can execute any code in here in any
 * other mode than FIQ...  Ok you can switch to another mode, but you can't
 * get out of that mode without clobbering one register.
 */
vector_fiq:
	disable_fiq
	subs	pc, lr, #4

/*=============================================================================
 * Address exception handler
 *-----------------------------------------------------------------------------
 * These aren't too critical.
 * (they're not supposed to happen, and won't happen in 32-bit data mode).
 */

vector_addrexcptn:
	b	vector_addrexcptn

/*
 * We group all the following data together to optimise
 * for CPUs with separate I & D caches.
 */
	.align	5

.LCvswi:
	.word	vector_swi

.LCsirq:
	.word	__temp_irq
.LCsund:
	.word	__temp_und
.LCsabt:
	.word	__temp_abt

__stubs_end:

	.equ	__real_stubs_start, .LCvectors + 0x200

.LCvectors:
	swi	SYS_ERROR0
	b	__real_stubs_start + (vector_und - __stubs_start)
	ldr	pc, __real_stubs_start + (.LCvswi - __stubs_start)
	b	__real_stubs_start + (vector_pabt - __stubs_start)
	b	__real_stubs_start + (vector_dabt - __stubs_start)
	b	__real_stubs_start + (vector_addrexcptn - __stubs_start)
	b	__real_stubs_start + (vector_irq - __stubs_start)
	b	__real_stubs_start + (vector_fiq - __stubs_start)

ENTRY(__trap_init)
	stmfd	sp!, {r4 - r6, lr}

	mov	r0, #0xff000000
	orr	r0, r0, #0x00ff0000		@ high vectors position
	adr	r1, .LCvectors			@ set up the vectors
	ldmia	r1, {r1, r2, r3, r4, r5, r6, ip, lr}
	stmia	r0, {r1, r2, r3, r4, r5, r6, ip, lr}

	add	r2, r0, #0x200
	adr	r0, __stubs_start		@ copy stubs to 0x200
	adr	r1, __stubs_end
1:	ldr	r3, [r0], #4
	str	r3, [r2], #4
	cmp	r0, r1
	blt	1b
	LOADREGS(fd, sp!, {r4 - r6, pc})

	.data

/*
 * Do not reorder these, and do not insert extra data between...
 */

__temp_irq:
	.word	0				@ saved lr_irq
	.word	0				@ saved spsr_irq
	.word	-1				@ old_r0
__temp_und:
	.word	0				@ Saved lr_und
	.word	0				@ Saved spsr_und
	.word	-1				@ old_r0
__temp_abt:
	.word	0				@ Saved lr_abt
	.word	0				@ Saved spsr_abt
	.word	-1				@ old_r0

	.globl	cr_alignment
	.globl	cr_no_alignment
cr_alignment:
	.space	4
cr_no_alignment:
	.space	4
