------------------------------------------------------------------------------
--                  GNAT RUN-TIME LIBRARY (GNARL) COMPONENTS                --
--               S Y S T E M . B B . P A R A M E T E R S                    --
--                                  S p e c                                 --
--                                                                          --
--  Xtensa LX7 (ESP32-S3) port skeleton -- dual-core SMP.                   --
------------------------------------------------------------------------------

--  This package defines basic parameters used by the low level tasking
--  system.  Target dependencies are isolated here.

pragma Restrictions (No_Elaboration_Code);

package System.BB.Parameters is
   pragma Pure;

   --------------------
   -- Hardware clock --
   --------------------

   Clock_Frequency : constant := 160_000_000;
   --  Hertz.  ESP-IDF's default ESP32-S3 CPU clock is 160 MHz (confirmed on
   --  hardware via the CCOUNT/CCOMPARE tick rate).  CCOUNT advances at the
   --  core clock, so this is also Ticks_Per_Second.

   Ticks_Per_Second : constant := Clock_Frequency;
   --  The System.BB.Time alarm is driven by the Xtensa CCOUNT/CCOMPARE
   --  registers, which advance at the core clock rate.
   --  TODO: track the actually-configured CPU clock.

   ----------------
   -- Interrupts --
   ----------------

   subtype Interrupt_Range is Natural range 0 .. 31;
   --  Xtensa provides 32 interrupt slots per core, routed from peripheral
   --  sources through the interrupt matrix.

   ------------
   -- Stacks --
   ------------

   Interrupt_Stack_Size : constant := 4 * 1024;  --  bytes
   --  Size of each of the (per-CPU) interrupt stacks

   Interrupt_Sec_Stack_Size : constant := 1024;
   --  Size of the secondary stack for interrupt handlers

   ----------
   -- CPUS --
   ----------

   Max_Number_Of_CPUs : constant := 2;
   --  ESP32-S3 is dual-core (PRO_CPU + APP_CPU).  SMP from the start.

   Multiprocessor : constant Boolean := Max_Number_Of_CPUs /= 1;
   --  True -- we are on a multiprocessor board.  Pulls in the SMP code
   --  paths (per-CPU ready queues, inter-core interrupts/spinlocks) that
   --  the Xtensa Board_Support layer must provide.

end System.BB.Parameters;
