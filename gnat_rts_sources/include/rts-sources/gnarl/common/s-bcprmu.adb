------------------------------------------------------------------------------
--                                                                          --
--                 GNAT RUN-TIME LIBRARY (GNARL) COMPONENTS                 --
--                                                                          --
--                 SYSTEM.BB.CPU_PRIMITIVES.MULTIPROCESSORS                 --
--                                                                          --
--                                 B o d y                                  --
--                                                                          --
--                     Copyright (C) 2010-2025, AdaCore                     --
--                                                                          --
-- GNARL is free software; you can  redistribute it  and/or modify it under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion. GNARL is distributed in the hope that it will be useful, but WITH- --
-- OUT ANY WARRANTY;  without even the  implied warranty of MERCHANTABILITY --
-- or FITNESS FOR A PARTICULAR PURPOSE.                                     --
--                                                                          --
-- As a special exception under Section 7 of GPL version 3, you are granted --
-- additional permissions described in the GCC Runtime Library Exception,   --
-- version 3.1, as published by the Free Software Foundation.               --
--                                                                          --
-- You should have received a copy of the GNU General Public License and    --
-- a copy of the GCC Runtime Library Exception along with this program;     --
-- see the files COPYING3 and COPYING.RUNTIME respectively.  If not, see    --
-- <http://www.gnu.org/licenses/>.                                          --
--                                                                          --
------------------------------------------------------------------------------

pragma Restrictions (No_Elaboration_Code);

with System.Multiprocessors;
with System.BB.Board_Support;
with System.BB.Threads;
with System.BB.Threads.Queues;
with System.BB.Protection;
with System.BB.Timing_Events;
with System.BB.Time;

package body System.BB.CPU_Primitives.Multiprocessors is
   use System.Multiprocessors;

   --------------------
   -- Start_All_CPUs --
   --------------------

   procedure Start_All_CPUs is
   begin
      --  Nothing to do when there's only one CPU

      if System.Multiprocessors.Number_Of_CPUs = 1 then
         return;
      end if;

      System.BB.Board_Support.Multiprocessors.Start_All_CPUs;
   end Start_All_CPUs;

   ------------------
   -- Poke_Handler --
   ------------------

   procedure Poke_Handler is
      Now : Time.Time;

   begin
      --  The access to the queues must be protected

      Protection.Enter_Kernel;

      --  Handle alarms in the case the alarm is system-wide

      Now := Time.Clock;

      --  Execute expired events of the current CPU

      Timing_Events.Execute_Expired_Timing_Events (Now);

      --  Wake up alarms

      Threads.Queues.Wakeup_Expired_Alarms (Now);

      --  Prompt delay-abort: a remote CPU may have asked us to alarm-cancel a
      --  task Delayed on this CPU (it cannot touch our per-CPU alarm queue).

      Threads.Queues.Run_Cross_Cancel;

      --  Re-arm this CPU's timer for its next pending alarm (this poke path
      --  does NOT otherwise reprogram CCOMPARE -> the next alarm would be lost).

      Time.Rearm_Alarm;

      Protection.Leave_Kernel;
   end Poke_Handler;

   ------------------
   -- Cancel_Delay --
   ------------------

   function Cancel_Delay (Thread : System.BB.Threads.Thread_Id) return Boolean is
      use type System.BB.Threads.Thread_States;
      Thread_CPU  : constant System.Multiprocessors.CPU :=
                      Threads.Get_CPU (Thread);
      Was_Delayed : Boolean;
   begin
      Protection.Enter_Kernel;

      --  Act only if the target is actually blocked in a delay.  (A task on a
      --  protected entry is Suspended and a CPU-bound one Runnable -- neither
      --  is woken here; this is specifically the prompt delay-abort path.)

      Was_Delayed := Thread.State = Threads.Delayed;

      if Was_Delayed then
         if Thread_CPU =
              System.BB.Board_Support.Multiprocessors.Current_CPU
         then
            --  Same core: unlink the alarm and make the task Runnable directly.
            --  It resumes from Delay_Until at the next scheduling point and
            --  raises Abort_Signal at its Abort_Undefer -- the same wake the
            --  timer would have done at the natural expiry, just now.

            Threads.Queues.Cancel_Alarm (Thread);

         else
            --  Other core: its alarm sits in that CPU's queue, which only that
            --  CPU may modify.  Record the request and Poke it; that CPU's
            --  Poke_Handler calls Run_Cross_Cancel to do the cancel locally.

            Threads.Queues.Request_Cross_Cancel (Thread);
            System.BB.Board_Support.Multiprocessors.Poke_CPU (Thread_CPU);
         end if;
      end if;

      Protection.Leave_Kernel;
      return Was_Delayed;
   end Cancel_Delay;

end System.BB.CPU_Primitives.Multiprocessors;
