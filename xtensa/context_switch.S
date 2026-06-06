/* ----------------------------------------------------------------------- *
 *                 GNAT RUN-TIME LIBRARY (GNARL) COMPONENTS                 *
 *                                                                          *
 *   Xtensa LX7 (ESP32-S3) windowed context switch and thread trampoline.   *
 *                                                                          *
 *   DUAL-FORMAT DISPATCH (Option A).  A thread is saved in one of two       *
 *   formats and resumed accordingly (cf. the FreeRTOS Xtensa port,          *
 *   reference/freertos-xtensa/):                                            *
 *     * SOLICITED (Frame_Kind = 0): a cooperative yield -- the live windows *
 *       are spilled to the thread's own stack, and it is resumed by a       *
 *       single 'retw' (window-underflow reloads the frame from the stack).  *
 *     * INTERRUPT (Frame_Kind = 1): the thread was preempted by a high-level *
 *       ISR; _xt_context_save wrote its FULL register state to an XT_STK     *
 *       frame, and it is resumed by _xt_context_restore + 'rfe'.            *
 *                                                                          *
 *   __gnat_context_switch saves the running thread SOLICITED (the           *
 *   cooperative Leave_Kernel path -- unchanged 213-PASS behaviour) and then *
 *   dispatches.  __gnat_preempt_dispatch records the running thread          *
 *   INTERRUPT and dispatches; it is tail-jumped from the ISR vector         *
 *   epilogue (highint5.S) and performs NO SPILL_ALL_WINDOWS.  Both paths     *
 *   share .Lresume, which resumes the next thread in its own format.        *
 *   WINDOWED ABI only.                                                      *
 * ----------------------------------------------------------------------- */

	.set	CTX_SP, 0	/* a1: stack pointer at the switch point  */
	.set	CTX_PS, 8	/* PS (processor state)                   */
	.set	CTX_A0, 12	/* a0: return address (call-size encoded) */
	.set	CTX_CP, 20	/* CP_State: ptr to the 72-byte FPU save  */
	.set	CTX_SAR,    24	/* SAR (shift amount register)            */
	.set	CTX_LBEG,   28	/* LBEG  \                                */
	.set	CTX_LEND,   32	/* LEND   > zero-overhead LOOP registers  */
	.set	CTX_LCOUNT, 36	/* LCOUNT/                                 */
	.set	CTX_KIND,   40	/* 0 = solicited, 1 = interrupt (Opt A)   */

	/* XT_STK interrupt-frame offsets (xtensa_context.h; MUST match highint5.S). */
	.set	XT_STK_PC,  4
	.set	XT_STK_PS,  8
	.set	XT_STK_A0,  12
	.set	XT_STK_A1,  16

/* --------------------------------------------------------------------------
 * void __gnat_context_switch (Address running_slot, Address first_slot);
 *   a2 = &Running_Thread_Table (CPU); a3 = &First_Thread_Table (CPU)
 *   Cooperative: spill + save the running thread SOLICITED, then dispatch.
 * -------------------------------------------------------------------------- */
	.text
	.align	4
	.global	__gnat_context_switch
	.type	__gnat_context_switch, @function
__gnat_context_switch:
	entry	a1, 32

	/* SPILL_ALL_WINDOWS (hardcoded 64-areg form). a0-a3 survive. */
	and	a12, a12, a12
	rotw	3
	and	a12, a12, a12
	rotw	3
	and	a12, a12, a12
	rotw	3
	and	a12, a12, a12
	rotw	3
	and	a12, a12, a12
	rotw	4

	l32i	a4, a2, 0		/* a4 = running context buffer */
	s32i	a1, a4, CTX_SP
	s32i	a0, a4, CTX_A0
	rsr.ps	a5
	s32i	a5, a4, CTX_PS
	rsr.sar	a5
	s32i	a5, a4, CTX_SAR
	rsr	a5, LBEG
	s32i	a5, a4, CTX_LBEG
	rsr	a5, LEND
	s32i	a5, a4, CTX_LEND
	rsr	a5, LCOUNT
	s32i	a5, a4, CTX_LCOUNT
	movi	a5, 0
	s32i	a5, a4, CTX_KIND	/* solicited */

	l32i	a8, a4, CTX_CP
	beqz	a8, .Lcs_nofp
	ssi	f0,  a8, 0
	ssi	f1,  a8, 4
	ssi	f2,  a8, 8
	ssi	f3,  a8, 12
	ssi	f4,  a8, 16
	ssi	f5,  a8, 20
	ssi	f6,  a8, 24
	ssi	f7,  a8, 28
	ssi	f8,  a8, 32
	ssi	f9,  a8, 36
	ssi	f10, a8, 40
	ssi	f11, a8, 44
	ssi	f12, a8, 48
	ssi	f13, a8, 52
	ssi	f14, a8, 56
	ssi	f15, a8, 60
	rur.fcr	a9
	s32i	a9, a8, 64
	rur.fsr	a9
	s32i	a9, a8, 68
.Lcs_nofp:
	j	.Lresume		/* a2 = &Running, a3 = &First */
	.size	__gnat_context_switch, . - __gnat_context_switch

/* --------------------------------------------------------------------------
 * __gnat_preempt_dispatch -- preemptive (interrupt-epilogue) dispatch.
 * Tail-jumped from the ISR vector epilogue (highint5.S), in the vector's
 * CLEAN SINGLE WINDOW (interruptee saved to XT_STK by _xt_context_save).
 * a1 = sp = that XT_STK frame.  NO spill here.  Record the interruptee
 * INTERRUPT, then share .Lresume.
 * -------------------------------------------------------------------------- */
	.align	4
	.global	__gnat_preempt_dispatch
	.type	__gnat_preempt_dispatch, @function
__gnat_preempt_dispatch:
	rsr.prid a6
	extui	a6, a6, 13, 1		/* a6 = core id (0/1) */
	movi	a2, __gnat_running_thread_table
	addx4	a2, a6, a2		/* a2 = &Running_Thread_Table (core) */
	movi	a3, first_thread_table
	addx4	a3, a6, a3		/* a3 = &First_Thread_Table (core)   */
	l32i	a4, a2, 0		/* a4 = interrupted context buffer   */
	s32i	a1, a4, CTX_SP		/* SP = its XT_STK frame             */
	movi	a5, 1
	s32i	a5, a4, CTX_KIND	/* interrupt */

	l32i	a8, a4, CTX_CP
	beqz	a8, .Lpd_nofp
	ssi	f0,  a8, 0
	ssi	f1,  a8, 4
	ssi	f2,  a8, 8
	ssi	f3,  a8, 12
	ssi	f4,  a8, 16
	ssi	f5,  a8, 20
	ssi	f6,  a8, 24
	ssi	f7,  a8, 28
	ssi	f8,  a8, 32
	ssi	f9,  a8, 36
	ssi	f10, a8, 40
	ssi	f11, a8, 44
	ssi	f12, a8, 48
	ssi	f13, a8, 52
	ssi	f14, a8, 56
	ssi	f15, a8, 60
	rur.fcr	a9
	s32i	a9, a8, 64
	rur.fsr	a9
	s32i	a9, a8, 68
.Lpd_nofp:
	j	.Lresume		/* a2 = &Running, a3 = &First */
	.size	__gnat_preempt_dispatch, . - __gnat_preempt_dispatch

/* --------------------------------------------------------------------------
 * .Lresume -- make First the running thread and resume it in its own format.
 *   a2 = &Running_Thread_Table (CPU); a3 = &First_Thread_Table (CPU).
 * -------------------------------------------------------------------------- */
	.align	4
.Lresume:
	l32i	a7, a3, 0		/* a7 = next context buffer */
	s32i	a7, a2, 0		/* Running_Thread_Table (CPU) := next */

	l32i	a8, a7, CTX_CP
	beqz	a8, .Lresume_nofp
	lsi	f0,  a8, 0
	lsi	f1,  a8, 4
	lsi	f2,  a8, 8
	lsi	f3,  a8, 12
	lsi	f4,  a8, 16
	lsi	f5,  a8, 20
	lsi	f6,  a8, 24
	lsi	f7,  a8, 28
	lsi	f8,  a8, 32
	lsi	f9,  a8, 36
	lsi	f10, a8, 40
	lsi	f11, a8, 44
	lsi	f12, a8, 48
	lsi	f13, a8, 52
	lsi	f14, a8, 56
	lsi	f15, a8, 60
	l32i	a9, a8, 64
	wur.fcr	a9
	l32i	a9, a8, 68
	wur.fsr	a9
.Lresume_nofp:
	l32i	a6, a7, CTX_KIND
	bnez	a6, .Lresume_int

	/* SOLICITED resume: reload SP/A0/SAR/LOOP/PS and 'retw'. */
	l32i	a1, a7, CTX_SP
	l32i	a0, a7, CTX_A0
	l32i	a5, a7, CTX_SAR
	wsr.sar	a5
	l32i	a5, a7, CTX_LBEG
	wsr	a5, LBEG
	l32i	a5, a7, CTX_LEND
	wsr	a5, LEND
	l32i	a5, a7, CTX_LCOUNT
	wsr	a5, LCOUNT
	l32i	a5, a7, CTX_PS
	wsr.ps	a5
	rsync
	retw

.Lresume_int:
	/* INTERRUPT resume: full restore from the XT_STK frame + 'rfe'. */
	l32i	a1, a7, CTX_SP		/* a1 = the thread's XT_STK frame */
	movi	a8, _xt_context_restore
	callx0	a8			/* restore a2-a15, SAR, LOOP from XT_STK */
	l32i	a0, a1, XT_STK_PS
	wsr.ps	a0
	l32i	a0, a1, XT_STK_PC
	wsr.epc1 a0
	l32i	a0, a1, XT_STK_A0
	l32i	a1, a1, XT_STK_A1
	rsync
	rfe

/* --------------------------------------------------------------------------
 * __gnat_start_thread -- first-entry trampoline for a new thread.
 * -------------------------------------------------------------------------- */
	.align	4
	.global	__gnat_start_thread
	.type	__gnat_start_thread, @function
__gnat_start_thread:
	mov	a6, a3			/* argument -> a6 (call4: callee a2)  */
	callx4	a2			/* wrapper (argument) -- never returns*/
.Lhang:
	j	.Lhang			/* safety net                        */
	.size	__gnat_start_thread, . - __gnat_start_thread
