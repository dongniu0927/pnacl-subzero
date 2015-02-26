; Tests basics and corner cases of x86-32 sandboxing, using -Om1 in
; the hope that the output will remain stable.  When packing bundles,
; we try to limit to a few instructions with well known sizes and
; minimal use of registers and stack slots in the lowering sequence.

; RUN: %p2i -i %s --filetype=obj --disassemble --args -Om1 \
; RUN:   -ffunction-sections -sandbox | FileCheck %s

declare void @call_target()
@global_byte = internal global [1 x i8] zeroinitializer
@global_short = internal global [2 x i8] zeroinitializer

; A direct call sequence uses the right mask and register-call sequence.
define void @test_direct_call() {
entry:
  call void @call_target()
  ret void
}
; CHECK-LABEL: test_direct_call
; CHECK: nop
; CHECK: 1b: {{.*}} call 1c
; CHECK-NEXT: 20:

; An indirect call sequence uses the right mask and register-call sequence.
define void @test_indirect_call(i32 %target) {
entry:
  %__1 = inttoptr i32 %target to void ()*
  call void %__1()
  ret void
}
; CHECK-LABEL: test_indirect_call
; CHECK: mov [[REG:.*]],DWORD PTR [esp
; CHECK-NEXT: nop
; CHECK: 1b: {{.*}} and [[REG]],0xffffffe0
; CHECK-NEXT: call [[REG]]
; CHECk-NEXT: 20:

; A return sequences uses the right pop / mask / jmp sequence.
define void @test_ret() {
entry:
  ret void
}
; CHECK-LABEL: test_ret
; CHECK: pop ecx
; CHECK-NEXT: and ecx,0xffffffe0
; CHECK-NEXT: jmp ecx

; A perfectly packed bundle should not have nops at the end.
define void @packed_bundle() {
entry:
  call void @call_target()
  ; bundle boundary
  %addr_byte = bitcast [1 x i8]* @global_byte to i8*
  %addr_short = bitcast [2 x i8]* @global_short to i16*
  store i8 0, i8* %addr_byte, align 1      ; 7-byte instruction
  store i16 0, i16* %addr_short, align 1   ; 9-byte instruction
  store i8 0, i8* %addr_byte, align 1      ; 7-byte instruction
  store i16 0, i16* %addr_short, align 1   ; 9-byte instruction
  ; bundle boundary
  store i8 0, i8* %addr_byte, align 1      ; 7-byte instruction
  store i16 0, i16* %addr_short, align 1   ; 9-byte instruction
  ret void
}
; CHECK-LABEL: packed_bundle
; CHECK: call
; CHECK-NEXT: 20: {{.*}} mov BYTE PTR
; CHECK-NEXT: 27: {{.*}} mov WORD PTR
; CHECK-NEXT: 30: {{.*}} mov BYTE PTR
; CHECK-NEXT: 37: {{.*}} mov WORD PTR
; CHECK-NEXT: 40: {{.*}} mov BYTE PTR
; CHECK-NEXT: 47: {{.*}} mov WORD PTR

; An imperfectly packed bundle should have one or more nops at the end.
define void @nonpacked_bundle() {
entry:
  call void @call_target()
  ; bundle boundary
  %addr_short = bitcast [2 x i8]* @global_short to i16*
  store i16 0, i16* %addr_short, align 1   ; 9-byte instruction
  store i16 0, i16* %addr_short, align 1   ; 9-byte instruction
  store i16 0, i16* %addr_short, align 1   ; 9-byte instruction
  ; nop padding
  ; bundle boundary
  store i16 0, i16* %addr_short, align 1   ; 9-byte instruction
  ret void
}
; CHECK-LABEL: nonpacked_bundle
; CHECK: call
; CHECK-NEXT: 20: {{.*}} mov WORD PTR
; CHECK-NEXT: 29: {{.*}} mov WORD PTR
; CHECK-NEXT: 32: {{.*}} mov WORD PTR
; CHECK-NEXT: 3b: {{.*}} nop
; CHECK: 40: {{.*}} mov WORD PTR

; A zero-byte instruction (e.g. local label definition) at a bundle
; boundary should not trigger nop padding.
define void @label_at_boundary(i32 %arg) {
entry:
  call void @call_target()
  ; bundle boundary
  %addr_short = bitcast [2 x i8]* @global_short to i16*
  store i16 0, i16* %addr_short, align 1   ; 9-byte instruction
  %cmp = icmp eq i32 %arg, 0               ; 23-byte lowering sequence
  ; label is here
  store i16 0, i16* %addr_short, align 1   ; 9-byte instruction
  ret void
}
; CHECK-LABEL: label_at_boundary
; CHECK: call
; We rely on the hideous 4-instruction 23-byte Om1 lowering sequence for icmp.
; CHECK-NEXT: 20: {{.*}} mov WORD PTR
; CHECK-NEXT: 29: {{.*}} cmp DWORD PTR
; CHECK-NEXT: 2e: {{.*}} mov DWORD PTR
; CHECK-NEXT: 36: {{.*}} je 40
; CHECK-NEXT: 38: {{.*}} mov DWORD PTR
; CHECK-NEXT: 40: {{.*}} mov WORD PTR

; Bundle lock without padding.
define void @bundle_lock_without_padding() {
entry:
  %addr_short = bitcast [2 x i8]* @global_short to i16*
  store i16 0, i16* %addr_short, align 1   ; 9-byte instruction
  ret void
}
; CHECK-LABEL: bundle_lock_without_padding
; CHECK: mov WORD PTR
; CHECK-NEXT: pop ecx
; CHECK-NEXT: and ecx,0xffffffe0
; CHECK-NEXT: jmp ecx

; Bundle lock with padding.
define void @bundle_lock_with_padding() {
entry:
  call void @call_target()
  ; bundle boundary
  %addr_byte = bitcast [1 x i8]* @global_byte to i8*
  %addr_short = bitcast [2 x i8]* @global_short to i16*
  store i8 0, i8* %addr_byte, align 1      ; 7-byte instruction
  store i16 0, i16* %addr_short, align 1   ; 9-byte instruction
  store i16 0, i16* %addr_short, align 1   ; 9-byte instruction
  ret void
  ; 3 bytes to restore stack pointer
  ; 1 byte to pop ecx
  ; bundle_lock
  ; 3 bytes to mask ecx
  ; This is now 32 bytes from the beginning of the bundle, so
  ; a 3-byte nop will need to be emitted before the bundle_lock.
  ; 2 bytes to jump to ecx
  ; bundle_unlock
}
; CHECK-LABEL: bundle_lock_with_padding
; CHECK: call
; CHECK-NEXT: 20: {{.*}} mov BYTE PTR
; CHECK-NEXT: 27: {{.*}} mov WORD PTR
; CHECK-NEXT: 30: {{.*}} mov WORD PTR
; CHECK-NEXT: 39: {{.*}} add esp,
; CHECK-NEXT: 3c: {{.*}} pop ecx
; CHECK-NEXT: 3d: {{.*}} nop
; CHECK-NEXT: 40: {{.*}} and ecx,0xffffffe0
; CHECK-NEXT: 43: {{.*}} jmp ecx

; Bundle lock align_to_end without any padding.
define void @bundle_lock_align_to_end_padding_0() {
entry:
  call void @call_target()
  ; bundle boundary
  %addr_short = bitcast [2 x i8]* @global_short to i16*
  store i16 0, i16* %addr_short, align 1   ; 9-byte instruction
  store i16 0, i16* %addr_short, align 1   ; 9-byte instruction
  store i16 0, i16* %addr_short, align 1   ; 9-byte instruction
  call void @call_target()                 ; 5-byte instruction
  ret void
}
; CHECK-LABEL: bundle_lock_align_to_end_padding_0
; CHECK: call
; CHECK-NEXT: 20: {{.*}} mov WORD PTR
; CHECK-NEXT: 29: {{.*}} mov WORD PTR
; CHECK-NEXT: 32: {{.*}} mov WORD PTR
; CHECK-NEXT: 3b: {{.*}} call

; Bundle lock align_to_end with one bunch of padding.
define void @bundle_lock_align_to_end_padding_1() {
entry:
  call void @call_target()
  ; bundle boundary
  %addr_byte = bitcast [1 x i8]* @global_byte to i8*
  store i8 0, i8* %addr_byte, align 1      ; 7-byte instruction
  store i8 0, i8* %addr_byte, align 1      ; 7-byte instruction
  store i8 0, i8* %addr_byte, align 1      ; 7-byte instruction
  call void @call_target()                 ; 5-byte instruction
  ret void
}
; CHECK-LABEL: bundle_lock_align_to_end_padding_1
; CHECK: call
; CHECK-NEXT: 20: {{.*}} mov BYTE PTR
; CHECK-NEXT: 27: {{.*}} mov BYTE PTR
; CHECK-NEXT: 2e: {{.*}} mov BYTE PTR
; CHECK-NEXT: 35: {{.*}} nop
; CHECK: 3b: {{.*}} call

; Bundle lock align_to_end with two bunches of padding.
define void @bundle_lock_align_to_end_padding_2(i32 %target) {
entry:
  call void @call_target()
  ; bundle boundary
  %addr_byte = bitcast [1 x i8]* @global_byte to i8*
  %addr_short = bitcast [2 x i8]* @global_short to i16*
  %__1 = inttoptr i32 %target to void ()*
  store i8 0, i8* %addr_byte, align 1      ; 7-byte instruction
  store i16 0, i16* %addr_short, align 1   ; 9-byte instruction
  store i16 0, i16* %addr_short, align 1   ; 9-byte instruction
  call void %__1()
  ; 4 bytes to load %target into a register
  ; bundle_lock align_to_end
  ; 3 bytes to mask the register
  ; This is now 32 bytes from the beginning of the bundle, so
  ; a 3-byte nop will need to be emitted before the bundle_lock,
  ; followed by a 27-byte nop before the mask/jump.
  ; 2 bytes to jump to the register
  ; bundle_unlock
  ret void
}
; CHECK-LABEL: bundle_lock_align_to_end_padding_2
; CHECK: call
; CHECK-NEXT: 20: {{.*}} mov BYTE PTR
; CHECK-NEXT: 27: {{.*}} mov WORD PTR
; CHECK-NEXT: 30: {{.*}} mov WORD PTR
; CHECK-NEXT: 39: {{.*}} mov [[REG:.*]],DWORD PTR [esp
; CHECK-NEXT: 3d: {{.*}} nop
; CHECK: 40: {{.*}} nop
; CHECK: 5b: {{.*}} and [[REG]],0xffffffe0
; CHECK-NEXT: 5e: {{.*}} call [[REG]]

; Stack adjustment state during an argument push sequence gets
; properly checkpointed and restored during the two passes, as
; observed by the stack adjustment for accessing stack-allocated
; variables.
define void @checkpoint_restore_stack_adjustment(i32 %arg) {
entry:
  call void @call_target()
  ; bundle boundary
  call void @checkpoint_restore_stack_adjustment(i32 %arg)
  ret void
}
; CHECK-LABEL: checkpoint_restore_stack_adjustment
; CHECK: call
; CHECK: sub esp,0x10
; The address of %arg should be [esp+0x20], not [esp+0x30].
; CHECK-NEXT: mov [[REG:.*]],DWORD PTR [esp+0x20]
; CHECK-NEXT: mov DWORD PTR [esp],[[REG]]
; CHECK: call
; CHECK: add esp,0x10