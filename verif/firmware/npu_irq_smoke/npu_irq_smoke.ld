/* Linker script for PicoRV32 NPU IRQ smoke firmware
 * Reset vector at 0x00000000, IRQ vector at 0x00000010
 */

ENTRY(_start)

SECTIONS
{
  . = 0x00000000;
  .text : {
    *(.text*)
  }
}
