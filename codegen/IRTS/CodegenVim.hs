{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns      #-}

module IRTS.CodegenVim
  ( codegenVim
  ) where

import           Control.Monad.Reader
import           Data.Char
import           Data.HashMap.Strict       (HashMap)
import qualified Data.HashMap.Strict       as HM
import           Data.List
import           Data.Semigroup
import qualified Data.Text                 as T
import           Idris.Core.TT             as Idris
import           IRTS.CodegenCommon
import           IRTS.Lang
import           IRTS.Simplified
import           Text.PrettyPrint.Mainland (pretty)
import qualified Vimscript.AST             as Vim
import qualified Vimscript.Render          as Vim

codegenVim :: CodeGenerator
codegenVim ci = do
  let prg = runReader (genProgram (simpleDecls ci)) HM.empty
  writeFile (outputFile ci) (pretty 200 (Vim.renderProgram prg))

type Gen a = Reader (HashMap Vim.Name Vim.ScopedName) a

vimName :: Idris.Name -> Vim.Name
vimName n = Vim.Name ("Idris_" <> foldMap vimChar (showCG n))
  where
    vimChar x
      | isAlpha x || isDigit x = T.singleton x
      | otherwise = "_" <> T.pack (show (fromEnum x)) <> "_"

lookupName :: Vim.Name -> Gen Vim.ScopedName
lookupName n = do
  names <- ask
  case HM.lookup n names of
    Just sn -> pure sn
    Nothing -> pure (Vim.ScopedName Vim.Global n)

withNewName :: Vim.ScopedName -> Gen a -> Gen a
withNewName sn@(Vim.ScopedName _ n) = local (HM.insert n sn)

withNewNames :: [Vim.ScopedName] -> Gen a -> Gen a
withNewNames ns g = foldl' (flip withNewName) g ns

loc :: Int -> Vim.Name
loc i = Vim.Name ("loc" <> T.pack (show i))

topLevelName :: Name -> Vim.ScopedName
topLevelName n = Vim.ScopedName Vim.Script (vimName n)

genProgram :: [(Name, SDecl)] -> Gen Vim.Program
genProgram defs = do
  let topLevelNames = map (topLevelName . fst) defs
  fns <- withNewNames topLevelNames (mapM genTopLevel defs)
  let start =
        Vim.Call (Vim.ScopedName Vim.Script (vimName (sMN 0 "runMain"))) []
  pure (Vim.Program (fns ++ [start]))

genTopLevel :: (Name, SDecl) -> Gen Vim.Stmt
genTopLevel (n, SFun _ args _i def) = genFunc n args def

genFunc :: Name -> [Name] -> SExp -> Gen Vim.Stmt
genFunc n args def =
  let fName = topLevelName n
  in withNewName fName $ do
       let args' = map loc [0 .. (length args - 1)]
           argsScoped = map (Vim.ScopedName Vim.Argument) args'
       stmts <-
         withNewNames
           argsScoped
           (genStmts (withNewNames argsScoped . pure . Vim.Return) def)
       pure (Vim.Function fName args' stmts)

genVar :: LVar -> Gen Vim.ScopedName
genVar =
  \case
    Loc n -> lookupName (loc n)
    Glob n -> lookupName (vimName n)

genStmts :: (Vim.Expr -> Gen Vim.Stmt) -> SExp -> Gen Vim.Block
genStmts ret =
  \case
    SV (Glob n) -> do
      vn <- lookupName (vimName n)
      stmt <- ret (Vim.Apply (Vim.Ref vn) [])
      pure [stmt]
    SV (Loc n) -> do
      ln <- lookupName (loc n)
      stmt <- ret (Vim.Ref ln)
      pure [stmt]
    SApp _ f params -> do
      f' <- lookupName (vimName f)
      params' <- mapM (fmap Vim.Ref . genVar) params
      stmt <- ret (Vim.Apply (Vim.Ref f') params')
      pure [stmt]
    SOp op args -> do
      args' <- mapM (fmap Vim.Ref . genVar) args
      stmt <- genPrimFn op args' >>= ret
      pure [stmt]
    SLet (Loc i) v sc -> do
      let n = loc i
          sn = Vim.ScopedName Vim.Local n
      let' <- genStmts (pure . Vim.Let n) v
      rest <- withNewName sn (genStmts (withNewName sn . ret) sc)
      pure (let' ++ rest)
    SUpdate _ e -> genStmts ret e
    SProj e i -> do
      v <- genVar e
      proj <- ret (Vim.Proj (Vim.Ref v) (Vim.ProjSingle (Vim.intExpr i)))
      pure [proj]
    SCon _ t _ args -> do
      let con = Vim.Prim (Vim.Integer (fromIntegral t))
      args' <- map Vim.Ref <$> mapM genVar args
      stmt <- ret (Vim.Prim (Vim.List (con : args')))
      pure [stmt]
    SCase _ e alts -> do
      e' <- Vim.Ref <$> genVar e
      genCases ret e' alts
    SChkCase e alts -> do
      e' <- Vim.Ref <$> genVar e
      genCases ret e' alts
    SConst c -> do
      stmt <- genConst c >>= ret
      pure [stmt]
    SForeign _ f params -> do
      params' <- mapM (fmap Vim.Ref . genVar . snd) params
      genForeign ret f params'
    SNothing -> do
      stmt <- ret (Vim.intExpr (0 :: Int))
      pure [stmt]
    SError x -> pure [Vim.BuiltInStmt "throw" (Vim.stringExpr (T.pack x))]
    expr -> error ("Expression not supported: " <> show expr)

projCons :: Vim.Expr -> Vim.Expr
projCons expr = Vim.Proj expr (Vim.ProjSingle (Vim.intExpr (0 :: Int)))

genCases :: (Vim.Expr -> Gen Vim.Stmt) -> Vim.Expr -> [SAlt] -> Gen Vim.Block
genCases ret c alts =
  foldM go ([], []) alts >>= \case
    ([], block) -> pure block
    (ifCase:elseIfCases, defaultBlock) ->
      let defaults =
            if null defaultBlock
              then Nothing
              else Just defaultBlock
      in pure [Vim.Cond (Vim.CondStmt ifCase elseIfCases defaults)]
  where
    go (cases, defaultCase) =
      \case
        SConstCase t exp' -> do
          test' <- Vim.BinOpApply Vim.Equals c <$> genConst t
          block <- genStmts ret exp'
          pure (cases ++ [Vim.CondCase test' block], defaultCase)
        SConCase lv t _ args exp' -> do
          let t' = Vim.intExpr (t :: Int)
              test' = Vim.BinOpApply Vim.Equals (projCons c) t'
              letPairs = zip [1 .. length args] [lv ..]
              newLocalNames =
                map (Vim.ScopedName Vim.Local . loc . snd) letPairs
          lets <- mapM letProject letPairs
          block <- withNewNames newLocalNames (genStmts ret exp')
          pure (cases ++ [Vim.CondCase test' (lets ++ block)], defaultCase)
          where letProject :: (Int, Int) -> Gen Vim.Stmt
                letProject (i, v) = do
                  let expr = Vim.Proj c (Vim.ProjSingle (Vim.intExpr i))
                  pure (Vim.Let (loc v) expr)
        SDefaultCase exp' -> do
          block <- genStmts ret exp'
          pure (cases, defaultCase ++ block)

genConst :: Const -> Gen Vim.Expr
genConst =
  \case
    (I i) -> pure (Vim.Prim (Vim.Integer (fromIntegral i)))
    (Ch i) -> pure (Vim.Prim (Vim.String (T.singleton i)))
    (BI i) -> pure (Vim.Prim (Vim.Integer i)) -- No support for Big Integer.
    (Str s) -> pure (Vim.Prim (Vim.String (T.pack s)))
    TheWorld -> pure (Vim.Prim (Vim.Integer 0))
    x
      | isTypeConst x -> pure (Vim.Prim (Vim.Integer 0))
    x -> error $ "Constant " ++ show x ++ " not compilable yet"

asBinOp :: PrimFn -> Maybe Vim.BinOp
asBinOp =
  \case
    LStrConcat -> Just Vim.Concat
    LStrCons -> Just Vim.Concat
    (LPlus (ATInt _)) -> Just Vim.Add
    (LMinus (ATInt _)) -> Just Vim.Subtract
    (LTimes (ATInt _)) -> Just Vim.Multiply
    (LEq (ATInt _)) -> Just Vim.Equals
    (LSLt (ATInt _)) -> Just Vim.LT
    (LSLe (ATInt _)) -> Just Vim.LTE
    (LSGt (ATInt _)) -> Just Vim.GT
    (LSGe (ATInt _)) -> Just Vim.GTE
    LStrEq -> Just Vim.Equals
    _ -> Nothing

genForeign :: (Vim.Expr -> Gen Vim.Stmt) -> FDesc -> [Vim.Expr] -> Gen Vim.Block
genForeign ret (FCon name) params =
  case (showCG name, params) of
    ("VIM_Echo", [x]) -> pure [Vim.BuiltInStmt "echo" x]
    ("VIM_ListEmpty", []) -> do
      stmt <- ret (Vim.listExpr [])
      pure [stmt]
    ("VIM_ListIndex", [i, l]) -> do
      stmt <- ret (Vim.Proj l (Vim.ProjSingle i))
      pure [stmt]
    ("VIM_ListSetAt", [i, x, l]) ->
      case l of
        Vim.Ref l' ->
          pure
            [ Vim.Assign
                (Vim.AssignProj (Vim.AssignName l') (Vim.ProjSingle i))
                x
            ]
        _ -> error "Cannot Idris_list_setAt without a list reference!"
    ("VIM_ListCons", [x, l]) -> do
      stmt <- ret (Vim.BinOpApply Vim.Add (Vim.listExpr [x]) l)
      pure [stmt]
    ("VIM_ListSnoc", [l, x]) -> do
      stmt <- ret (Vim.BinOpApply Vim.Add l (Vim.listExpr [x]))
      pure [stmt]
    ("VIM_ListConcat", [l1, l2]) -> do
      stmt <- ret (Vim.BinOpApply Vim.Add l1 l2)
      pure [stmt]
    (other, _) -> error ("Foreign function not supported: " ++ other)
genForeign ret (FApp (showCG -> "VIM_BuiltIn") [FStr name]) params = do
  stmt <- ret (Vim.Apply (Vim.Ref (Vim.builtIn (T.pack name))) params)
  pure [stmt]
genForeign _ f _ = error ("Foreign function not supported: " ++ show f)

genPrimFn :: PrimFn -> [Vim.Expr] -> Gen Vim.Expr
genPrimFn LWriteStr [_, s] = pure (Vim.applyBuiltIn "Idris_echo" [s])
genPrimFn LStrRev [x] =
  pure
    (Vim.applyBuiltIn
       "join"
       [ Vim.applyBuiltIn
           "reverse"
           [Vim.applyBuiltIn "split" [x, Vim.stringExpr ".\\zs"]]
       , Vim.stringExpr ""
       ])
genPrimFn LStrLen [x] = pure (Vim.applyBuiltIn "len" [x])
genPrimFn LStrHead [x] =
  pure (Vim.Proj x (Vim.ProjSingle (Vim.intExpr (0 :: Int))))
genPrimFn LStrIndex [x, y] = pure (Vim.Proj x (Vim.ProjSingle y))
genPrimFn LStrSubstr [i, l, s] =
  pure (Vim.Proj s (Vim.ProjBoth i (Vim.BinOpApply Vim.Subtract l i)))
genPrimFn LStrTail [x] =
  pure (Vim.Proj x (Vim.ProjFrom (Vim.intExpr (0 :: Int))))
genPrimFn (LIntStr _) [x] =
  pure (Vim.BinOpApply Vim.Concat x (Vim.stringExpr ""))
genPrimFn (LStrInt _) [x] = pure (Vim.applyBuiltIn "str2nr" [x])
genPrimFn (LChInt _) [x] = pure (Vim.applyBuiltIn "char2nr" [x])
genPrimFn (LIntCh _) [x] = pure (Vim.applyBuiltIn "nr2char" [x])
genPrimFn (LSExt _ _) [x] = pure x
genPrimFn (LTrunc _ _) [x] = pure x
genPrimFn (LZExt _ _) [x] = pure x
genPrimFn (asBinOp -> Just binOp) [l, r] = pure (Vim.BinOpApply binOp l r)
genPrimFn (LExternal n) params =
  pure (Vim.applyBuiltIn (T.pack (showCG n)) params)
genPrimFn LReadStr _ =
  error "Cannot read strings using the idris-vimscript-backend!"
genPrimFn f exps =
  error $ "PrimFn " ++ show f ++ " " ++ show exps ++ " not implemented!"
