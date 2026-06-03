------------------------------------------------------------------------------
--                                                                          --
--                         GNAT RUN-TIME COMPONENTS                         --
--                                                                          --
--                        S Y S T E M . T E X T _ I O                       --
--                                                                          --
--                                 B o d y                                  --
--                                                                          --
--          Copyright (C) 2011-2026, Free Software Foundation, Inc.         --
--                                                                          --
-- GNAT is free software;  you can  redistribute it  and/or modify it under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  GNAT is distributed in the hope that it will be useful, but WITH- --
-- OUT ANY WARRANTY;  without even the  implied warranty of MERCHANTABILITY --
-- or FITNESS FOR A PARTICULAR PURPOSE.                                     --
--                                                                          --
-- As a special exception under Section 7 of GPL version 3, you are granted --
-- additional permissions described in the GCC Runtime Library Exception,   --
-- version 3.1, as published by the Free Software Foundation.               --
--                                                                          --
------------------------------------------------------------------------------

--  ESP32-S3 implementation: send characters to the built-in USB-serial-JTAG
--  controller (the console used by the ROM/2nd-stage bootloader and the
--  CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG devkit console -- i.e. the /dev/ttyACM
--  port).  The peripheral is already clocked and enabled by the bootloader, so
--  System.Text_IO.Put can write to it directly with no driver setup.

with Interfaces;             use Interfaces;
--  System (the ancestor) is directly visible here; no `with` needed.

package body System.Text_IO is

   --  USB-serial-JTAG registers (ESP32-S3 TRM).
   --    EP1      (0x6003_8000): write byte 0..7 -> serial-in (TX) FIFO.
   --    EP1_CONF (0x6003_8004): bit0 WR_DONE   -> flush the FIFO as a packet;
   --                            bit1 IN_EP_DATA_FREE (RO) -> FIFO has room.
   EP1 : Unsigned_32
     with Volatile, Address => System'To_Address (16#6003_8000#), Import;
   EP1_Conf : Unsigned_32
     with Volatile, Address => System'To_Address (16#6003_8004#), Import;

   Data_Free : constant Unsigned_32 := 2;   -- EP1_CONF bit 1
   Wr_Done   : constant Unsigned_32 := 1;   -- EP1_CONF bit 0

   ---------
   -- Get --
   ---------

   function Get return Character is
   begin
      raise Program_Error;
      return ASCII.NUL;
   end Get;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize is
   begin
      Initialized := True;
   end Initialize;

   -----------------
   -- Is_Rx_Ready --
   -----------------

   function Is_Rx_Ready return Boolean is
   begin
      return False;
   end Is_Rx_Ready;

   -----------------
   -- Is_Tx_Ready --
   -----------------

   function Is_Tx_Ready return Boolean is
   begin
      return (EP1_Conf and Data_Free) /= 0;
   end Is_Tx_Ready;

   ---------
   -- Put --
   ---------

   procedure Put (C : Character) is
      Spins : Natural := 0;
   begin
      --  Wait for FIFO room, but bounded: if no USB host is draining the port
      --  we drop the character rather than hang the runtime forever.
      while (EP1_Conf and Data_Free) = 0 loop
         exit when Spins > 200_000;
         Spins := Spins + 1;
      end loop;
      EP1 := Character'Pos (C);
      EP1_Conf := Wr_Done;        --  commit the byte to the host
   end Put;

   ----------------------------
   -- Use_Cr_Lf_For_New_Line --
   ----------------------------

   function Use_Cr_Lf_For_New_Line return Boolean is
   begin
      return True;
   end Use_Cr_Lf_For_New_Line;

end System.Text_IO;
