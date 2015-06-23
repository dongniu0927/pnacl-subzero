//===- subzero/src/IceAssembler.cpp - Assembler base class ----------------===//
// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
//
// Modified by the Subzero authors.
//
// This is forked from Dart revision 39313.
// Please update the revision if we merge back changes from Dart.
// https://code.google.com/p/dart/wiki/GettingTheSource
//
//===----------------------------------------------------------------------===//
//
//                        The Subzero Code Generator
//
// This file is distributed under the University of Illinois Open Source
// License. See LICENSE.TXT for details.
//
//===----------------------------------------------------------------------===//
//
// This file implements the Assembler base class.
//
//===----------------------------------------------------------------------===//

#include "IceAssembler.h"
#include "IceGlobalContext.h"
#include "IceOperand.h"

namespace Ice {

static uintptr_t NewContents(Assembler &Assemblr, intptr_t Capacity) {
  uintptr_t Result = Assemblr.allocateBytes(Capacity);
  return Result;
}

AssemblerFixup *AssemblerBuffer::createFixup(FixupKind Kind,
                                             const Constant *Value) {
  AssemblerFixup *F =
      new (Assemblr.allocate<AssemblerFixup>()) AssemblerFixup();
  F->set_position(0);
  F->set_kind(Kind);
  F->set_value(Value);
  if (!Assemblr.getPreliminary())
    Fixups.push_back(F);
  return F;
}

#ifndef NDEBUG
AssemblerBuffer::EnsureCapacity::EnsureCapacity(AssemblerBuffer *buffer) {
  if (buffer->cursor() >= buffer->limit())
    buffer->extendCapacity();
  // In debug mode, we save the assembler buffer along with the gap
  // size before we start emitting to the buffer. This allows us to
  // check that any single generated instruction doesn't overflow the
  // limit implied by the minimum gap size.
  Buffer = buffer;
  Gap = computeGap();
  // Make sure that extending the capacity leaves a big enough gap
  // for any kind of instruction.
  assert(Gap >= kMinimumGap);
  // Mark the buffer as having ensured the capacity.
  assert(!buffer->hasEnsuredCapacity()); // Cannot nest.
  buffer->HasEnsuredCapacity = true;
}

AssemblerBuffer::EnsureCapacity::~EnsureCapacity() {
  // Unmark the buffer, so we cannot emit after this.
  Buffer->HasEnsuredCapacity = false;
  // Make sure the generated instruction doesn't take up more
  // space than the minimum gap.
  intptr_t delta = Gap - computeGap();
  assert(delta <= kMinimumGap);
}
#endif // !NDEBUG

AssemblerBuffer::AssemblerBuffer(Assembler &Asm) : Assemblr(Asm) {
  const intptr_t OneKB = 1024;
  static const intptr_t kInitialBufferCapacity = 4 * OneKB;
  Contents = NewContents(Assemblr, kInitialBufferCapacity);
  Cursor = Contents;
  Limit = computeLimit(Contents, kInitialBufferCapacity);
#ifndef NDEBUG
  HasEnsuredCapacity = false;
#endif // !NDEBUG

  // Verify internal state.
  assert(capacity() == kInitialBufferCapacity);
  assert(size() == 0);
}

AssemblerBuffer::~AssemblerBuffer() = default;

void AssemblerBuffer::extendCapacity() {
  intptr_t old_size = size();
  intptr_t old_capacity = capacity();
  const intptr_t OneMB = 1 << 20;
  intptr_t new_capacity = std::min(old_capacity * 2, old_capacity + OneMB);
  if (new_capacity < old_capacity) {
    llvm::report_fatal_error(
        "Unexpected overflow in AssemblerBuffer::ExtendCapacity");
  }

  // Allocate the new data area and copy contents of the old one to it.
  uintptr_t new_contents = NewContents(Assemblr, new_capacity);
  memmove(reinterpret_cast<void *>(new_contents),
          reinterpret_cast<void *>(Contents), old_size);

  // Compute the relocation delta and switch to the new contents area.
  intptr_t delta = new_contents - Contents;
  Contents = new_contents;

  // Update the cursor and recompute the limit.
  Cursor += delta;
  Limit = computeLimit(new_contents, new_capacity);

  // Verify internal state.
  assert(capacity() == new_capacity);
  assert(size() == old_size);
}

llvm::StringRef Assembler::getBufferView() const {
  return llvm::StringRef(reinterpret_cast<const char *>(Buffer.contents()),
                         Buffer.size());
}

void Assembler::emitIASBytes(GlobalContext *Ctx) const {
  Ostream &Str = Ctx->getStrEmit();
  intptr_t EndPosition = Buffer.size();
  intptr_t CurPosition = 0;
  const intptr_t FixupSize = 4;
  for (const AssemblerFixup *NextFixup : fixups()) {
    intptr_t NextFixupLoc = NextFixup->position();
    for (intptr_t i = CurPosition; i < NextFixupLoc; ++i) {
      Str << "\t.byte 0x";
      Str.write_hex(Buffer.load<uint8_t>(i));
      Str << "\n";
    }
    Str << "\t.long ";
    NextFixup->emit(Ctx, Buffer.load<RelocOffsetT>(NextFixupLoc));
    if (fixupIsPCRel(NextFixup->kind()))
      Str << " - .";
    Str << "\n";
    CurPosition = NextFixupLoc + FixupSize;
    assert(CurPosition <= EndPosition);
  }
  // Handle any bytes that are not prefixed by a fixup.
  for (intptr_t i = CurPosition; i < EndPosition; ++i) {
    Str << "\t.byte 0x";
    Str.write_hex(Buffer.load<uint8_t>(i));
    Str << "\n";
  }
}

} // end of namespace Ice