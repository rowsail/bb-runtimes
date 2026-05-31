------------------------------------------------------------------------------
--                  GNAT RUN-TIME LIBRARY (GNARL) COMPONENTS                --
--                S Y S T E M . B B . B O A R D _ S U P P O R T             --
--                                  B o d y                                 --
--                                                                          --
--  Xtensa LX7 (ESP32-S3) port.                                            --
--                                                                          --
--  Clock/alarm use the Xtensa CCOUNT (free-running cycle counter) and      --
--  CCOMPARE0 (internal timer 0 -> interrupt 6, level 1).  ESP-IDF's        --
--  FreeRTOS tick runs off the systimer, so all CCOMPAREn are free.  The    --
--  CCOMPARE0 interrupt is registered through ESP-IDF's low-level CPU        --
--  interrupt dispatch (esp_cpu_intr_set_handler, in glue.c) and routed to  --
--  System.BB.Interrupts.Interrupt_Wrapper, which runs the alarm handler    --
--  and performs the context switch on return.  (Coexistence step toward    --
--  a full FreeRTOS handoff.)                                               --
------------------------------------------------------------------------------

pragma Restrictions (No_Elaboration_Code);

with System.Machine_Code;       use System.Machine_Code;
with System.BB.CPU_Primitives;
with System.BB.Threads.Queues;

package body System.BB.Board_Support is

   use System.Multiprocessors;

   Alarm_Interrupt_ID : constant System.BB.Interrupts.Interrupt_ID := 16;
   --  CCOMPARE2 raises Xtensa internal interrupt 16 (level 5).  We OWN the
   --  level-5 vector (xt_highint5, in the application's startup glue), so the
   --  interrupt entry/exit and the context switch are fully native (no
   --  ESP-IDF interrupt dispatch).  The vector saves the interrupted context,
   --  calls __gnat_timer_interrupt below, then restores + RFE.

   procedure Timer_Interrupt
     with Export, Convention => C, External_Name => "__gnat_timer_interrupt";
   --  Called from the level-5 vector: run the alarm handler, then context
   --  switch if a higher-priority task became ready (interrupt epilogue).

   procedure Native_Enable_Tick
     with Import, Convention => C, External_Name => "native_enable_tick";
   --  Enables int 16 (esp_cpu_intr_enable) once the handler is attached.

   procedure Park_Alarm;
   --  Push CCOMPARE2 ~a full period ahead so int 16 cannot fire spuriously
   --  before a real alarm is programmed.

   ----------------
   -- Park_Alarm --
   ----------------

   procedure Park_Alarm is
   begin
      Asm ("rsr.ccount a3"     & ASCII.LF & ASCII.HT &
           "addi a3, a3, -1"   & ASCII.LF & ASCII.HT &
           "wsr.ccompare2 a3"  & ASCII.LF & ASCII.HT &
           "rsync",
           Clobber  => "a3",
           Volatile => True);
   end Park_Alarm;

   --------------------
   -- Timer_Interrupt --
   --------------------

   procedure Timer_Interrupt is
   begin
      System.BB.Interrupts.Interrupt_Wrapper (Alarm_Interrupt_ID);

      --  Interrupt epilogue: switch to the highest-priority ready thread if it
      --  differs from the one we interrupted.  Context_Switch saves the
      --  interrupted thread "solicited" (returning here); the level-5 vector
      --  performs the final register restore + RFE when it is resumed.

      if System.BB.Threads.Queues.Context_Switch_Needed then
         System.BB.CPU_Primitives.Context_Switch;
      end if;
   end Timer_Interrupt;

   ----------------------
   -- Initialize_Board --
   ----------------------

   procedure Initialize_Board is
   begin
      Park_Alarm;             --  no spurious int 16 before a real alarm
   end Initialize_Board;

   ----------
   -- Time --
   ----------

   package body Time is

      function Read_Count return Timer_Interval;
      pragma Inline (Read_Count);

      ----------------
      -- Read_Count --
      ----------------

      function Read_Count return Timer_Interval is
         Count : Timer_Interval;
      begin
         Asm ("rsr.ccount %0",
              Outputs  => Timer_Interval'Asm_Output ("=r", Count),
              Volatile => True);
         return Count;
      end Read_Count;

      ----------------
      -- Read_Clock --
      ----------------

      function Read_Clock return BB.Time.Time is
      begin
         return BB.Time.Time (Read_Count);
      end Read_Clock;

      ------------------------
      -- Max_Timer_Interval --
      ------------------------

      function Max_Timer_Interval return Timer_Interval is
        (Timer_Interval'Last);

      ---------------
      -- Set_Alarm --
      ---------------

      procedure Set_Alarm (Ticks : Timer_Interval) is
         Deadline : constant Timer_Interval := Read_Count + Ticks;
      begin
         Asm ("wsr.ccompare2 %0" & ASCII.LF & ASCII.HT & "rsync",
              Inputs   => Timer_Interval'Asm_Input ("r", Deadline),
              Volatile => True);
      end Set_Alarm;

      -------------------------
      -- Clear_Alarm_Interrupt --
      -------------------------

      procedure Clear_Alarm_Interrupt is
         --  Writing CCOMPARE0 clears the pending int 6.  Park it almost a full
         --  period ahead so it does not immediately re-fire; the next
         --  Set_Alarm programs the real deadline.
         Park : constant Timer_Interval := Read_Count - 1;
      begin
         Asm ("wsr.ccompare2 %0" & ASCII.LF & ASCII.HT & "rsync",
              Inputs   => Timer_Interval'Asm_Input ("r", Park),
              Volatile => True);
      end Clear_Alarm_Interrupt;

      ---------------------------
      -- Install_Alarm_Handler --
      ---------------------------

      procedure Install_Alarm_Handler
        (Handler : System.BB.Interrupts.Interrupt_Handler)
      is
      begin
         System.BB.Interrupts.Attach_Handler
           (Handler, Alarm_Interrupt_ID, Interrupt_Priority'Last);
         Native_Enable_Tick;   --  safe to let int 6 fire now
      end Install_Alarm_Handler;

   end Time;

   ----------------
   -- Interrupts --
   ----------------

   package body Interrupts is

      ---------------------------
      -- Priority_Of_Interrupt --
      ---------------------------

      function Priority_Of_Interrupt
        (Interrupt : System.BB.Interrupts.Interrupt_ID)
         return System.Any_Priority
      is
         pragma Unreferenced (Interrupt);
      begin
         return Interrupt_Priority'First;
      end Priority_Of_Interrupt;

      -------------------------------
      -- Install_Interrupt_Handler --
      -------------------------------

      procedure Install_Interrupt_Handler
        (Interrupt : System.BB.Interrupts.Interrupt_ID;
         Prio      : Interrupt_Priority)
      is
         pragma Unreferenced (Interrupt, Prio);
      begin
         null;  --  ESP-IDF already routes the interrupt; nothing extra here.
      end Install_Interrupt_Handler;

      --------------------------
      -- Set_Current_Priority --
      --------------------------

      procedure Set_Current_Priority (Priority : Integer) is
         pragma Unreferenced (Priority);
      begin
         --  Gross interrupt masking is handled by CPU_Primitives
         --  Disable/Enable_Interrupts; per-priority ceiling masking is future
         --  work.
         null;
      end Set_Current_Priority;

      ----------------
      -- Power_Down --
      ----------------

      procedure Power_Down is
      begin
         Asm ("waiti 0", Volatile => True);
      end Power_Down;

   end Interrupts;

   ---------------------
   -- Multiprocessors --
   ---------------------

   package body Multiprocessors is

      function Number_Of_CPUs return CPU is (CPU'Last);

      function Current_CPU return CPU is
         Result : Integer;
      begin
         --  ESP32-S3: PRID bit 13 selects the core (0 = PRO_CPU/core 0,
         --  1 = APP_CPU/core 1).  System.Multiprocessors.CPU is 1-based, so
         --  the running CPU id is that bit plus one.
         Asm ("rsr.prid %0"        & ASCII.LF & ASCII.HT &
              "extui  %0, %0, 13, 1",
              Outputs  => Integer'Asm_Output ("=r", Result),
              Volatile => True);
         return CPU (Result + 1);
      end Current_CPU;

      procedure Poke_CPU (CPU_Id : CPU) is
         pragma Unreferenced (CPU_Id);
      begin
         null;  --  TODO Phase 5: inter-core interrupt (IPI).
      end Poke_CPU;

      procedure Start_All_CPUs is
      begin
         null;  --  TODO Phase 5: release APP_CPU.
      end Start_All_CPUs;

   end Multiprocessors;

end System.BB.Board_Support;
