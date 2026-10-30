    .syntax unified
    .arm
    .section .text.start, "ax"
    .global _start
_start:
    ldr r4, =bases
next_base:
    ldr r0, [r4], #4
    cmp r0, #0
    beq spin
    mov r1, #16
    str r1, [r0, #0x10]        @ BAUDDIV
    mov r1, #1
    str r1, [r0, #0x08]        @ CTRL: TX enable
    ldr r2, =msg
1:  ldrb r3, [r2], #1
    cmp r3, #0
    beq next_base
    mov r5, #1000              @ bounded TX-full wait
2:  ldr r1, [r0, #0x04]
    tst r1, #1
    beq 4f
    subs r5, r5, #1
    bne 2b
4:  str r3, [r0, #0x00]        @ DATA
    b 1b
spin:
    b spin
    .section .rodata
    .align 2
bases:
    .word 0xe0205000, 0xe0206000, 0xe0207000, 0xe0208000, 0xe7c00000, 0
msg:
    .asciz "AN536-R52-BOOT-OK\n"
