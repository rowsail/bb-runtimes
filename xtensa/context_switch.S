/* ----------------------------------------------------------------------- *
 *                 GNAT RUN-TIME LIBRARY (GNARL) COMPONENTS                 *
 *                                                                          *
 *   Xtensa LX7 (ESP32-S3) windowed context switch and thread trampoline.   *
 *                                                                          *
 *   Cooperative (synchronous) switch.  Both an existing task and a brand-  *
 *   new task are resumed by a single 'retw': after SPILL_ALL_WINDOWS the   *
 *   live windows are on the task's own stack, so 'retw' window-underflow-   *
 *   reloads the resumed window from there.  A new task is given, by         *
 *   Initialize_Context, a fabricated call4 underflow frame at the top of    *
 *   its stack so the same 'retw' lands in __gnat_start_thread with the      *
 *   entry point and argument already in a2/a3.  WINDOWED ABI only.         *
 *                                                                          *
 *   Modelled on the FreeRTOS Xtensa solicited path; see                     *
 *   reference/freertos-xtensa/.  Requires window overflow/underflow         *
 *   vectors installed (ESP-IDF does this at boot) and PS.WOE = 1.           *
 * ----------------------------------------------------------------------- */

/* Context_Buffer field offsets (System.BB.CPU_Specific, s-bbcpsp__xtensa.ads).
   Context_Buffer is the first field of the Thread_Descriptor, so a thread
   pointer is also its context-buffer pointer. */
	.set	CTX_SP, 0	/* a1: stack pointer at the switch point  */
	.set	CTX_PS, 8	/* PS (processor state)                   */
	.set	CTX_A0, 12	/* a0: return address (call-size encoded) */

/* --------------------------------------------------------------------------
 * void __gnat_context_switch (Address running_slot, Address first_slot);
 *
 *   a2 = &Running_Thread_Table (CPU)  -- slot holding the running thread ptr
 *   a3 = &First_Thread_Table   (CPU)  -- slot holding the first ready  ptr
 * -------------------------------------------------------------------------- */
	.text
	.align	4
	.global	__gnat_context_switch
	.type	__gnat_context_switch, @function
__gnat_context_switch:
	entry	a1, 32

	/* Flush all live register windows of the running thread to its own
	   stack FIRST, while only a0-a3 are in use.  CRITICAL: do not clobber
	   a4-a15 before the spill -- they may hold live windows of caller
	   frames that SPILL_ALL_WINDOWS must write to the stack (per ESP-IDF
	   xtensa_context.S).  In task context PS already has EXCM=0 and WOE=1,
	   so no PS adjustment is needed.
	   Inlined SPILL_ALL_WINDOWS (Zephyr technique): no-op writes to high
	   registers trap into window-overflow exceptions that do the spilling;
	   a full WINDOWBASE rotation returns to this frame.  a0-a3 survive.
	   NOTE: this is the XCHAL_NUM_AREGS == 64 sequence (rotw total = 16).
	   ESP32-S3 (LX7) has 64 address registers -- the Alire gnat_xtensa
	   toolchain reports 32 (it targets base ESP32/LX6), so we cannot rely
	   on the compiler's XCHAL_NUM_AREGS and hardcode the S3 (64) form. */
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

	/* Now save the running thread's resume state (high regs safe to use). */
	l32i	a4, a2, 0		/* a4 = running context buffer       */
	s32i	a1, a4, CTX_SP		/* save SP at the switch point       */
	s32i	a0, a4, CTX_A0		/* save return address (encodes size)*/
	rsr.ps	a5
	s32i	a5, a4, CTX_PS		/* save PS                           */

	/* Make First the running thread and load its resume state. */
	l32i	a7, a3, 0		/* a7 = next context buffer          */
	s32i	a7, a2, 0		/* Running_Thread_Table (CPU) := next*/

	l32i	a1, a7, CTX_SP		/* SP                                */
	l32i	a0, a7, CTX_A0		/* return address (call-size encoded)*/
	l32i	a5, a7, CTX_PS		/* PS                                */
	wsr.ps	a5
	rsync

	/* Resume: 'retw' rotates WINDOWBASE back per a0's encoded call size and
	   window-underflow-reloads the resumed frame from its stack (SP=a1).
	   For an existing task this is its real spilled frame; for a new task
	   it is the call4 frame fabricated by Initialize_Context, landing in
	   __gnat_start_thread. */
	retw
	.size	__gnat_context_switch, . - __gnat_context_switch

/* --------------------------------------------------------------------------
 * __gnat_start_thread -- first-entry trampoline for a new thread.
 *
 * Reached by the 'retw' above via a fabricated call4 underflow frame, so the
 * window-underflow handler has already loaded this window's registers:
 *     a0 = 0           (terminate backtrace)
 *     a1 = task SP
 *     a2 = entry point (the GNARL wrapper)
 *     a3 = argument
 * The GNARL wrapper does not return.
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
