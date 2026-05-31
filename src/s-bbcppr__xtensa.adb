------------------------------------------------------------------------------
--                  GNAT RUN-TIME LIBRARY (GNARL) COMPONENTS                --
--               S Y S T E M . B B . C P U _ P R I M I T I V E S            --
--                                  B o d y                                 --
--                                                                          --
--  Xtensa LX6 / LX7 (ESP32 / ESP32-S3) port SKELETON.                      --
--                                                                          --
--  Initialize_Context / Initialize_Stack are implemented; Context_Switch    --
--  and the interrupt/trap routines remain documented STUBS.  TODOs anchor   --
--  each to the vendored FreeRTOS Xtensa reference (reference/freertos-      --
--  xtensa/, esp-idf v5.4.4):                                                --
--    * components/xtensa/xtensa_context.S  (_xt_context_save/_restore)     --
--    * components/xtensa/xtensa_vectors.S  (window over/underflow, vectors)--
--    * components/freertos/.../portable/xtensa/port.c  (pxPortInitialise-  --
--      Stack: the initial frame this Initialize_Context mirrors)           --
--  The SPARC/LEON port (s-bbcppr__sparc.adb) is the closest existing       --
--  windowed-register analogue in bb-runtimes.                              --
------------------------------------------------------------------------------

pragma Restrictions (No_Elaboration_Code);

with System.Machine_Code;            use System.Machine_Code;
with System.Multiprocessors;
with System.BB.Threads.Queues;
with System.BB.Board_Support;

package body System.BB.CPU_Primitives is

   Initial_PS : constant := 16#0005_002F#;
   --  Initial PS (Processor State) for a task's first entry (windowed ABI):
   --    INTLEVEL = 15 (0x0F)    -- start masked; the runtime lowers it per
   --                               the task priority after the switch
   --                               (cf. SPARC starting with PIL = 15).
   --    UM       = 1  (0x20)    -- user vector mode.
   --    CALLINC  = 1  (1 << 16) -- entered as if 'call4'd.
   --    WOE      = 1  (1 << 18) -- window overflow detection enabled.
   --  EXCM is left clear: first entry is reached by a jump, not by 'rfe'.

   --  Initialize_Context leaves a 16-byte data slot at the very top of a new
   --  task's stack and sets the task SP 16 bytes below it (an ABI base save
   --  area sits between).  __gnat_start_thread therefore reads the task entry
   --  point at [SP + 16] and the argument at [SP + 20].

   --------------------
   -- Context_Switch --
   --------------------

   procedure Context_Switch is
      use System.BB.Threads.Queues;

      procedure Switch_Asm (Running_Slot, First_Slot : System.Address);
      pragma Import (Asm, Switch_Asm, "__gnat_context_switch");
      --  The windowed register switch itself, in xtensa/context_switch.S.
      --  Each argument is the address of a Thread_Table slot; the asm
      --  dereferences it to the thread descriptor, whose first field is the
      --  Context_Buffer.

      CPU_Id : constant System.Multiprocessors.CPU :=
                 Board_Support.Multiprocessors.Current_CPU;

      New_Priority : constant Integer :=
                       First_Thread_Table (CPU_Id).Active_Priority;
   begin
      --  Set the board-level interrupt priority for the incoming thread
      --  (full CPU interrupt disabling is handled separately by the switch).
      --  Mirrors the RISC-V port.

      if New_Priority < Interrupt_Priority'Last then
         Board_Support.Interrupts.Set_Current_Priority (New_Priority);
      end if;

      --  Perform the register switch (also updates Running_Thread_Table).

      Switch_Asm
        (Running_Thread_Table (CPU_Id)'Address,
         First_Thread_Table (CPU_Id)'Address);
   end Context_Switch;

   ----------------------
   -- Initialize_Stack --
   ----------------------

   procedure Initialize_Stack
     (Base          : Address;
      Size          : Storage_Elements.Storage_Offset;
      Stack_Pointer : out Address)
   is
      use System.Storage_Elements;

      Top  : constant Integer_Address := To_Integer (Base + Size);
      Algn : constant Integer_Address := CPU_Specific.Stack_Alignment;
   begin
      --  Xtensa stacks grow downward; return the top of the region aligned
      --  down to the ABI stack alignment.  Initialize_Context lays the task's
      --  initial frame below this address.
      Stack_Pointer := To_Address ((Top / Algn) * Algn);
   end Initialize_Stack;

   ------------------------
   -- Initialize_Context --
   ------------------------

   procedure Initialize_Context
     (Buffer          : not null access Context_Buffer;
      Program_Counter : System.Address;
      Argument        : System.Address;
      Stack_Pointer   : System.Address)
   is
      use System.Storage_Elements;

      procedure Start_Thread_Asm;
      pragma Import (Asm, Start_Thread_Asm, "__gnat_start_thread");
      --  Trampoline the first Context_Switch resumes into: the windowed
      --  switch's 'retw' underflow-reloads the fabricated frame below, then
      --  Start_Thread_Asm calls the entry with the argument.

      Align : constant Integer_Address := CPU_Specific.Stack_Alignment;

      Top : constant Integer_Address :=
              (To_Integer (Stack_Pointer) / Align) * Align;
      --  16-byte aligned top of the task stack, used as the switch SP.

      Task_SP : constant Integer_Address := Top - 32;
      --  The trampoline window's own stack pointer (below the save area).

      --  WindowUnderflow4 reloads the resumed window's a0..a3 from
      --  [switch_SP - 16 .. switch_SP - 4], i.e. [Top-16 .. Top-4].
      --  Lay out a call4 frame so the trampoline starts cleanly:
      A0_Slot : System.Address;                  --  -> a0 = 0 (end backtrace)
      for A0_Slot'Address use To_Address (Top - 16);
      A1_Slot : System.Address;                  --  -> a1 = trampoline SP
      for A1_Slot'Address use To_Address (Top - 12);
      A2_Slot : System.Address;                  --  -> a2 = entry point
      for A2_Slot'Address use To_Address (Top - 8);
      A3_Slot : System.Address;                  --  -> a3 = argument
      for A3_Slot'Address use To_Address (Top - 4);

   begin
      --  The environment task already has a stack and context: nothing to do.

      if Program_Counter = Null_Address then
         return;
      end if;

      A0_Slot := Null_Address;
      A1_Slot := To_Address (Task_SP);
      A2_Slot := Program_Counter;
      A3_Slot := Argument;

      --  Resume state: SP = Top is the value 'retw' uses to find the frame
      --  above; A0 = trampoline address (a 0x4....... address whose top two
      --  bits already encode a call4 return, so 'retw' raises Underflow4).

      Buffer.all :=
        (SP        => To_Address (Top),
         PC        => Null_Address,
         PS        => To_Address (Initial_PS),
         A0        => Start_Thread_Asm'Address,
         THREADPTR => Null_Address,
         CP_State  => Null_Address);
   end Initialize_Context;

   ---------------------------
   -- Install_Error_Handlers --
   ---------------------------

   procedure Install_Error_Handlers is
   begin
      --  TODO Phase 3: point the Xtensa exception vectors at a handler that
      --  maps synchronous traps (IllegalInstruction, LoadStoreError,
      --  division-by-zero, ...) to the matching Ada exceptions.
      null;
   end Install_Error_Handlers;

   ------------------------
   -- Disable_Interrupts --
   ------------------------

   procedure Disable_Interrupts is
      Old : Integer;
   begin
      --  Raise PS.INTLEVEL to mask all maskable interrupts (level 15).
      Asm ("rsil %0, 15",
           Outputs  => Integer'Asm_Output ("=r", Old),
           Volatile => True);
   end Disable_Interrupts;

   -----------------------
   -- Enable_Interrupts --
   -----------------------

   procedure Enable_Interrupts (Level : Integer) is
      Old : Integer;
   begin
      --  Simplified for bring-up: software priorities re-enable all
      --  interrupts (INTLEVEL = 0); a request to stay at the highest
      --  priority keeps them masked.  A full priority->INTLEVEL mapping for
      --  hardware-interrupt priorities is future work (Board_Support).
      if Level >= Interrupt_Priority'Last then
         Asm ("rsil %0, 15",
              Outputs  => Integer'Asm_Output ("=r", Old),
              Volatile => True);
      else
         Asm ("rsil %0, 0",
              Outputs  => Integer'Asm_Output ("=r", Old),
              Volatile => True);
      end if;
   end Enable_Interrupts;

   --------------------
   -- Initialize_CPU --
   --------------------

   procedure Initialize_CPU is
   begin
      --  TODO Phase 3: per-CPU bring-up after ESP-IDF hands the core over
      --  (PS, CPENABLE=0, vector base / VECBASE, interrupt matrix routing).
      --  Runs on each of the two ESP32-S3 cores under SMP.
      null;
   end Initialize_CPU;

end System.BB.CPU_Primitives;
