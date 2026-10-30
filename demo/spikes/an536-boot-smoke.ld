ENTRY(_start)
MEMORY { DDR (rwx) : ORIGIN = 0x20000000, LENGTH = 16M }
SECTIONS {
  .text : { *(.text.start) *(.text*) *(.rodata*) } > DDR
  .data : { *(.data*) } > DDR
  .bss  : { *(.bss*) }  > DDR
}
