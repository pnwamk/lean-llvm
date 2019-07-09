import init.data.rbmap

import .ast
import .bv
import .pp
import .llvm_lib
import .simulate

open llvm.

def main (xs : List String) : IO UInt32 := do

  ctx ← newLLVMContext,
  mb ← newMemoryBufferFromFile xs.head,
  m ← parseBitcodeFile mb ctx >>= extractModule,

  IO.println (pp.render (pp_module m)),

  let res :=
     runFunc (symbol.mk "fib")
             [ runtime_value.int 32 (bv.from_nat 32 8)
             ]
             (state.mk RBMap.empty m) in
  match res with
  | (Sum.inl err) := throw err
  | (Sum.inr (runtime_value.int _ x, _)) :=
       do IO.println ("0x" ++ (Nat.toDigits 16 x.to_nat).asString),
          pure 0
  | _ := pure 0
