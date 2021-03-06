module Vimscript.FFI

%default total

mutual
  public export
  data VimFn t = MkVimFn t

  public export
  data VIM_FnTypes : Type -> Type where
    VIM_Fn : VIM_Types s -> VIM_FnTypes t -> VIM_FnTypes (s -> t)
    VIM_FnIO : VIM_Types t -> VIM_FnTypes (IO' l t)
    VIM_FnBase : VIM_Types t -> VIM_FnTypes t

  public export
  data VIM_Types : Type -> Type where
    VIM_Str    : VIM_Types String
    VIM_Int    : VIM_Types Int
    VIM_Float  : VIM_Types Double
    VIM_Unit   : VIM_Types ()
    VIM_Raw    : VIM_Types (Raw a)
    VIM_FnT    : VIM_FnTypes t -> VIM_Types (VimFn t)

public export
data VIM_Foreign
  = VIM_Echo
  | VIM_ListEmpty
  | VIM_ListIndex
  | VIM_ListCons
  | VIM_ListSnoc
  | VIM_ListConcat
  | VIM_ListSetAt
  | VIM_BuiltIn String

%error_reverse
public export
FFI_VIM : FFI
FFI_VIM = MkFFI VIM_Types VIM_Foreign String

%error_reverse
public export
VIM_IO : Type -> Type
VIM_IO = IO' FFI_VIM

IO : Type -> Type
IO a = IO' FFI_VIM a
