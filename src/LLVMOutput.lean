import Init.Data.Array
import Init.Data.Int
import Init.Data.RBMap
import Init.System.IO

import LeanLLVM.AST
import LeanLLVM.PP
import LeanLLVM.DataLayout
import LeanLLVM.LLVMCodes
import LeanLLVM.LLVMFFI

namespace LLVM
namespace Output

@[reducible]
def SymMap := RBMap Symbol FFI.Value (λx y => decide (x < y))

@[reducible]
def BlockMap := RBMap BlockLabel FFI.Value (λx y => decide (x.label < y.label))

@[reducible]
def ValueMap := RBMap Ident FFI.Value (λx y => decide (x < y))

@[reducible]
def TypeMap := RBMap String FFI.Type_ (λx y => decide (x < y))

structure ValueContext :=
(symbolMap : SymMap)
(blockMap  : BlockMap)
(valueMap  : ValueMap)
(typeMap   : TypeMap)

def ValueContext.init : ValueContext := 
  { symbolMap := RBMap.empty,
    blockMap  := RBMap.empty,
    valueMap  := RBMap.empty,
    typeMap   := RBMap.empty
  }

end Output

@[reducible]
def Output (a:Type) := IO.Ref Output.ValueContext → IO a.

namespace Output

instance monad : Monad Output :=
  { bind := λa b mx mf r => mx r >>= λx => mf x r
  , pure := λa x r => pure x
  }

instance monadExcept : MonadExcept IO.Error Output :=
  { throw := λa err r => throw err,
    catch := λa m handle r => catch (m r) (λerr => handle err r),
  }

instance mIO : MonadIO Output :=
  { monadLift := λa m r => m
  }

def run {a:Type} (m:Output a) : IO (Output.ValueContext × a) := do
  r <- IO.mkRef Output.ValueContext.init;
  a <- m r;
  vc <- r.get;
  pure (vc, a)

def alterSymbolMap (f:SymMap → SymMap) : Output Unit := λr => 
  r.modify (λvc => { vc with symbolMap := f vc.symbolMap })

def lookupAlias (nm:String) : Output (Option FFI.Type_) := λr => do
  vc <- r.get;
  pure (vc.typeMap.find? nm)

/-
def createFunction (m:Module) (nm:symbol) : Output LLVMFunction :=
  do f <- newFunction m nm.symbol;
     alterSymbolMap (λsm => sm.insert
-/

end Output

def outputFloatType : FloatType → Code.TypeID
| FloatType.half      => Code.TypeID.half
| FloatType.float     => Code.TypeID.float
| FloatType.double    => Code.TypeID.double
| FloatType.fp128     => Code.TypeID.fp128
| FloatType.x86FP80   => Code.TypeID.x86FP80
| FloatType.ppcFP128  => Code.TypeID.ppcFP128

def outputPrimType (ctx:FFI.Context) : PrimType → IO FFI.Type_
| PrimType.label         => FFI.newPrimitiveType ctx Code.TypeID.label
| PrimType.token         => FFI.newPrimitiveType ctx Code.TypeID.token
| PrimType.void          => FFI.newPrimitiveType ctx Code.TypeID.void
| PrimType.floatType ft  => FFI.newPrimitiveType ctx (outputFloatType ft)
| PrimType.x86mmx        => FFI.newPrimitiveType ctx Code.TypeID.x86mmx
| PrimType.metadata      => FFI.newPrimitiveType ctx Code.TypeID.metadata
| PrimType.integer n     => FFI.newIntegerType ctx n

partial def outputType (ctx:FFI.Context) : LLVMType → Output FFI.Type_
| LLVMType.prim pt => monadLift (outputPrimType ctx pt)
| LLVMType.alias nm => do
  x <- Output.lookupAlias nm;
  match x with
  | some tp => pure tp
  | none => throw (IO.userError ("Unknown type alias: " ++ nm))
| LLVMType.array n t => do
  t' <- outputType t;
  monadLift $ FFI.newArrayType n t'
| LLVMType.vector n t => do
  t' <- outputType t;
  monadLift $ FFI.newVectorType n t'
| LLVMType.ptr t => do
  t' <- outputType t;
  monadLift $ FFI.newPointerType t'
| LLVMType.funType ret args varargs => do
  ret' <- outputType ret;
  args' <- Array.mapM outputType args;
  monadLift $ FFI.newFunctionType ret' args' varargs
| LLVMType.struct packed tps => do
  tps' <- tps.mapM outputType;
  monadLift $ FFI.newLiteralStructType packed tps'

def setupTypeAlias (ctx:FFI.Context) (nm:String) : Output FFI.Type_ := λr => do 
  vc <- r.get;
  tp <- FFI.newOpaqueStructType ctx nm;
  let vc' := { vc with typeMap := vc.typeMap.insert nm tp };
  r.set vc';
  pure tp

def finalizeTypeAlias (ctx:FFI.Context) (ty:FFI.Type_) : TypeDeclBody → Output Unit
| TypeDeclBody.opaque => pure ()
| TypeDeclBody.defn (LLVMType.struct packed tps) => do
  tps' <- tps.mapM (outputType ctx);
  monadLift (FFI.setStructTypeBody ty packed tps');
  pure ()
| TypeDeclBody.defn _ => 
  throw (IO.userError "type alias defintion must be a struct body")

-- Process type aliases in two phases.  First, allocate named, opaque struct
-- types for each alias and record them in the value context.  Next, process
-- the bodies of type aliases and set the body of the non-opaque named struct types.
--
-- This two-phase approach ensures that recursive struct groups are properly handled.
def outputTypeAliases (ctx:FFI.Context) (tds:Array TypeDecl) : Output Unit := do
   fs <- tds.mapM (λtd => 
     setupTypeAlias ctx td.name >>= λty => pure (finalizeTypeAlias ctx ty td.decl));
   Array.iterateM fs () (λ_ action _ => action)


def outputDeclare (ctx:FFI.Context) (m:FFI.Module) (d:Declare) : Output Unit := do
  funtp <- outputType ctx (LLVMType.funType d.retType d.args d.varArgs);
  f <- monadLift (FFI.newFunction m funtp d.name.symbol);
  Output.alterSymbolMap (λsm => sm.insert d.name (FFI.functionToValue f))

def outputDefine (ctx:FFI.Context) (m:FFI.Module) (d:Define) : Output Unit := do
  let argTypes := d.args.map (λa => a.type);
  funtp <- outputType ctx (LLVMType.funType d.retType argTypes d.varArgs);
  f <- monadLift (FFI.newFunction m funtp d.name.symbol);
  Output.alterSymbolMap (λsm => sm.insert d.name (FFI.functionToValue f));
  -- TODO!!!
  pure ()

def outputModule (ctx:FFI.Context) (m:Module) : Output FFI.Module := do
  outputTypeAliases ctx m.types;
  let modnm := match m.sourceName with
               | some nm => nm
               | none    => "";
  ffimod <- monadLift (FFI.newModule ctx modnm);
  Array.iterateM m.declares () (λ_ decl _ => outputDeclare ctx ffimod decl);
  Array.iterateM m.defines () (λ_ defn _ => outputDefine ctx ffimod defn);
  pure ffimod

end LLVM
