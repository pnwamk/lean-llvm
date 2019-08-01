import init.data.array
import init.data.int
import init.data.rbmap
import init.data.string

import .ast
import .bv
import .pp
import .type_context
import .value

namespace llvm.

structure frame :=
  (locals   : sim.regMap)
  (func     : define)
  (curr     : block_label)
  (prev     : Option block_label)
  (framePtr : bytes).

instance frameInh : Inhabited frame := Inhabited.mk
  { locals := RBMap.empty
  , func   := llvm.define.mk none (llvm_type.prim_type prim_type.void) (symbol.mk "") Array.empty false Array.empty none none Array.empty (strmap_empty _) none
  , curr   := block_label.named ""
  , prev   := none
  , framePtr := bytes.mk 0
  }.

structure state :=
  (mem : sim.memMap)
  (mod : module)
  (dl  : data_layout)
  (heapAllocPtr : bytes)
  (stackPtr : bytes)
  (symmap : @RBMap symbol (bv 64) (λx y => decide (x < y)))
  (revsymmap : @RBMap (bv 64) symbol (λx y => decide (x < y)))
.

-- Heap allocation counts up.  Find the next aligned value and return it,
-- advancing the heap allocation pointer x bytes beyond.
def allocOnHeap (x:bytes) (a:alignment) (st:state) : Prod (bv 64) state :=
  let ptr  := padToAlignment st.heapAllocPtr a;
  let ptr' := ptr.add x;
  ( bv.from_nat 64 ptr.val, { st with heapAllocPtr := ptr' } )

-- Stack allocation counts down.  Find the next aligned value that provides
-- enough space and return it, advancing the stack pointer to this point.
def allocOnStack (x:bytes) (a:alignment) (st:state) : Prod (bv 64) state :=
  let ptr := padDownToAlignment (st.stackPtr.sub x) a;
  ( bv.from_nat 64 ptr.val, { st with stackPtr := ptr })

def allocFunctionSymbol (s:symbol) (st:state) : state :=
  let (ptr, st') := allocOnHeap (bytes.mk 16) (alignment.mk 4) st; -- 16 bytes with 16 byte alignment, rather arbitrarily
  { st' with
    symmap := st.symmap.insert s ptr,
    revsymmap := st.revsymmap.insert ptr s
  }.

def initializeState (mod : module) (dl:data_layout) : state :=
  let st0 : state :=
             { mem := RBMap.empty
             , mod := mod
             , dl  := dl
             , heapAllocPtr := bytes.mk 0
             , stackPtr := bytes.mk (2^64)
             , symmap := RBMap.empty
             , revsymmap := RBMap.empty
             };
  List.foldr allocFunctionSymbol st0
    (List.map declare.name mod.declares.toList ++ List.map define.name mod.defines.toList).

structure sim_conts (z:Type) :=
  (kerr : IO.Error → z) /- error continuation -/
  (kret : Option sim.value → state → z) /- return continuation -/
  (kcall : (Option sim.value → state → z) → symbol → List sim.value → state → z)
         /- call continuation -/
  (kjump : block_label → frame → state → z) /- jump continuation -/
.

structure sim (a:Type) :=
  (runSim :
     ∀{z:Type},
     (sim_conts z)           /- nonlocal continuations -/ →
     (a → frame → state → z) /- normal continuation -/ →
     (frame → state → z)).

namespace sim

instance monad : Monad sim :=
  { bind := λa b mx mf => sim.mk (λz conts k =>
       mx.runSim conts (λx => (mf x).runSim conts k))
  , pure := λa x => sim.mk (λz _ k => k x)
  }

instance monadExcept : MonadExcept IO.Error sim :=
  { throw := λa err => sim.mk (λz conts _k _frm _st => conts.kerr err)
  , catch := λa m handle => sim.mk (λz conts k frm st =>
      let conts' := { conts with kerr := λerr => (handle err).runSim conts k frm st };
      m.runSim conts' k frm st)
  }.

def setFrame (frm:frame) : sim Unit :=
  sim.mk (λz _ k _ st => k () frm st).

def getFrame : sim frame :=
  sim.mk (λz _ k frm st => k frm frm st).

def modifyFrame (f: frame → frame) : sim Unit :=
  sim.mk (λz _ k frm st => k () (f frm) st).

def getState : sim state :=
  sim.mk (λz _ k frm st => k st frm st).

def setState (st:state) : sim Unit :=
  sim.mk (λz _ k frm _ => k () frm st).

def assignReg (reg:ident) (v:value) : sim Unit :=
  modifyFrame (λfrm => { frm with locals := RBMap.insert frm.locals reg v }).

def lookupReg (reg:ident) : sim value :=
  do frm <- getFrame;
     match RBMap.find frm.locals reg with
     | none     => throw (IO.userError ("unassigned register: " ++ reg.asString))
     | (some v) => pure v

def returnVoid {a} : sim a :=
  sim.mk (λz conts _k frm st => conts.kret none { st with stackPtr := frm.framePtr }).

def returnValue {a} (v:sim.value) : sim a :=
  sim.mk (λz conts _k frm st => conts.kret (some v) { st with stackPtr := frm.framePtr }).

def jump {a} (l:block_label) : sim a :=
  sim.mk (λz conts _k frm st => conts.kjump l frm st).

def call (s:symbol) (args:List value) : sim (Option value) :=
  sim.mk (λz conts k frm st => conts.kcall (λv => k v frm) s args st).

end sim.
end llvm.