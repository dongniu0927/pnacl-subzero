; Tests various aspects of x86 immediate encoding. Some encodings are shorter.
; For example, the encoding is shorter for 8-bit immediates or when using EAX.
; This assumes that EAX is chosen as the first free register in O2 mode.

; RUN: %p2i --filetype=obj --disassemble -i %s --target=x8664 --args -O2 | FileCheck %s

define internal i32 @testMul32Imm32Imm32(i32 %a) {
entry:
  %mul = mul i32 6, 1540483477
  ret i32 %mul
}
; CHECK-LABEL: testMul32Imm32Imm32
; CHECK: mov eax,0x6
; CHECK: imul eax,eax,0x5bd1e995
