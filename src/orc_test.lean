import .llvm_ffi

def main (xs : List String) : IO UInt32 := do
  initNativeFns;
  s ← newCompilerSession (newTriple (processTriple Unit.unit));
  let args := [xs.head,
               "-stdlib=libc++",
               "-fcxx-exceptions",
               "-I/Users/jhendrix/opt/lean4/include",
               "-I/Users/jhendrix/opt/llvm-8.0.0/include/c++/v1",
               "-I/Users/jhendrix/opt/llvm-8.0.0/lib/clang/8.0.0/include"
               ];
  addFromClang s args.toArray;
  f ← lookupFn s "__Z5l_addPN4lean6objectES1_" (Nat → Nat → Nat);
  IO.println (f 1 2);
  pure 0
