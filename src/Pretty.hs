{-# LANGUAGE FlexibleInstances #-}

module Pretty where

import Control.Monad.State

import Syntax
import Data.List
import Control.Monad

-- | Simple show instances for BinOps
instance Show BOp where
  show Add = "+"
  show Sub = "-"
  show Mul = "*"
  show Div = "/"
  show Mod = "%"

  show And  = "&&"
  show Or   = "||"
  show Eq   = "=="
  show Neq  = "!="
  show Gte  = ">="
  show Gt   = ">"
  show Lte  = "<="
  show Lt   = "<"

  show BitAnd = "&"
  show BitOr  = "|"
  show BitXor = "^"

instance Show OpaqueType where
  show Uniform   = "uniform"
  show Attribute = "attribute"
  show Varying   = "varying"

instance Show Opaque where
  show (Opaque ot t n) = (++";\n") . mconcat $ intersperse " " $ [show ot, show t, n]

-- | Wraps a list with a pair of elements
wrapList :: a -> a -> [a] -> [a]
wrapList l r es = l : es ++ [r]

-- | Constant preface for all shaders
preface :: String
preface = intercalate "\n" [
  "//",
  "// Generated by FDSSL",
  "//",
  "#ifdef GL_ES",
  "precision highp float;",
  "precision highp int;",
  "#endif"] ++ "\n\n"

-- | Represents indentation levels
data Indent = Indent Indent | None

instance Show Indent where
  show (Indent t) = "\t" ++ show t
  show None       = ""

-- | Pretty printer state describes a current indentation level
-- & an ongoing printed program as state
type Printer a = StateT (Indent,[String]) IO a

-- | Adds an indentation
indent :: Printer ()
indent = do
  (t,s) <- get
  put $ (Indent t,s)

-- | Removes an indentation level
dedent :: Printer ()
dedent = do
  (t,s) <- get
  case t of
    (Indent t) -> put (t,s)
    _       -> return ()

-- | Trim tabs off of strings
trimTabs :: String -> String
trimTabs ls = filter (\c -> c /= '\t') ls

-- | Pop the last evaluted entry on the printer stack
-- Auto-trims tabs off of the entries
pop :: Printer String
pop = do
  (t,(s:ls)) <- get
  put (t,ls)
  -- trim all indentation off
  return $ trimTabs s

-- | ``Pretty Print'' function, allows accumulating an ongoing concrete rep
pPrint :: String -> Printer ()
pPrint s = do
  (t,s') <- get
  put (t,(show t ++ s) : s')

-- | Terminate the last 'statement' expression with a semi-colon
-- Used to finish off statements, which are top-level exprs
pTermLast :: Printer ()
pTermLast = do
  (t,(s:ls)) <- get
  put (t,(s ++ ";") : ls)

-- | Pretty prints an Env, which is a list of opaque types
prettyEnv :: Env -> Printer ()
prettyEnv e = mapM_ (pPrint . show) e

-- | Pretty print strings into a wrapped list
-- implies that these strings are the pretty printed params/args
prettyParams :: [String] -> String
prettyParams =  concat . wrapList "(" ")" . intersperse ", "

-- | Pretty prints a function
prettyFunc :: Func -> Printer ()
prettyFunc (Func name params typ exprs) = do
  let sig = show typ ++ " " ++ name ++ prettyParams (map (\(n,t) -> show t ++ " " ++ n) params) ++ " {"
  pPrint sig
  indent
  mapM_ prettyStmt exprs
  dedent
  pPrint "}\n"

-- | Pretty prints an expr into a return statement
prettyReturn :: Expr -> Printer ()
prettyReturn e = do
  e' <- prettyPop e
  pPrint $ "return " ++ e'
  pTermLast

-- | Pretty print a statement, a standalone expr
prettyStmt :: Expr -> Printer ()
prettyStmt m@(Mut _ _ _)    = prettyExpr m >> pTermLast
prettyStmt c@(Const _ _ _)  = prettyExpr c >> pTermLast
prettyStmt u@(Update _ _)   = prettyExpr u >> pTermLast
prettyStmt o@(Out _ _)      = prettyExpr o >> pTermLast
prettyStmt a@(App _ _)      = prettyExpr a >> pTermLast
-- literals are immediate returns
prettyStmt i@(I _)          = prettyReturn i
prettyStmt b@(B _)          = prettyReturn b
prettyStmt f@(F _)          = prettyReturn f
prettyStmt d@(D _)          = prettyReturn d
prettyStmt v@(V2 _)         = prettyReturn v
prettyStmt v@(V3 _)         = prettyReturn v
prettyStmt v@(V4 _)         = prettyReturn v
prettyStmt m@(Mat4 _)       = prettyReturn m
prettyStmt r@(Ref _)        = prettyReturn r
--prettyStmt a@(App _ _)      = prettyReturn a
prettyStmt b@(BinOp _ _ _)  = prettyReturn b
prettyStmt a@(AccessN _ _)  = prettyReturn a
prettyStmt a@(AccessI _ _)  = prettyReturn a
-- normally print all others w/out semi-colons afterwards
prettyStmt s = prettyExpr s

-- | Pretty print an expression
prettyExpr :: Expr -> Printer ()
prettyExpr (Mut t n e) = do
  let t' = show t ++ " " ++ n ++ " = "
  -- evaluate & pop the last expr result
  e' <- prettyPop e
  -- add it & continue
  pPrint $ t' ++ e'
prettyExpr (Const t n e) = do
  -- same as mut
  let t' = "const " ++ show t ++ " " ++ n ++ " = "
  e' <- prettyPop e
  pPrint $ t' ++ e'
prettyExpr (Update n e) = do
  let t = n ++ " = "
  e' <- prettyPop e
  pPrint $ t ++ e'
prettyExpr (Out n e) = do
  let t = n ++ " = "
  e' <- prettyPop e
  pPrint $ t ++ e'
prettyExpr NOp = return ()
prettyExpr (Branch c t e) = do
  c' <- prettyPop c
  pPrint $ "if (" ++ c' ++ ") {"
  indent
  mapM_ prettyStmt t
  dedent
  pPrint "} else {"
  indent
  mapM_ prettyStmt e
  dedent
  pPrint "}"
prettyExpr (For i (Just n) e) = do
  i' <- prettyPop i
  pPrint $ "for (int " ++ n ++ " = 0; " ++ n ++ " < 10000; " ++ n ++ "++) {"
  indent
  mapM_ prettyStmt e
  pPrint $ "if ("++ n ++" >= " ++ i' ++ ") { break; }"
  dedent
  pPrint "}"
prettyExpr (For i Nothing e) = do
  i' <- prettyPop i
  pPrint $ "for (int fdssl_cntr = 0; fdssl_cntr < 10000; fdssl_cntr" ++ "++) {"
  indent
  mapM_ prettyStmt e
  pPrint $ "if (fdssl_cntr >= " ++ i' ++ ") { break; }"
  dedent
  pPrint "}"
prettyExpr (SComment s) = pPrint $ "// " ++ s
prettyExpr (BComment s) = pPrint $ "/*" ++ s ++ "*/"
prettyExpr (I i) = pPrint $ show i
prettyExpr (B b) = pPrint $ if b then "true" else "false"
prettyExpr (F f) = pPrint $ show f
prettyExpr (D f) = pPrint $ show f
prettyExpr (V2 (a,b)) = do
  ls <- mapM prettyPop [a,b]
  pPrint $ "vec2" ++ prettyParams ls
prettyExpr (V3 (a,b,c)) = do
  ls <- mapM prettyPop [a,b,c]
  pPrint $ "vec3" ++ prettyParams ls
prettyExpr (V4 (a,b,c,d)) = do
  ls <- mapM prettyPop [a,b,c,d]
  pPrint $ "vec4" ++ prettyParams ls
prettyExpr (Mat4 m) = error "Cannot pretty print mat4, not done yet"
prettyExpr (Ref r) = pPrint r
prettyExpr (App n ls) = do
  ls' <- mapM (\x -> prettyExpr x >> pop) ls
  pPrint $ n ++ prettyParams ls'
prettyExpr (BinOp b e1 e2) = do
  e1' <- prettyPop e1
  e2' <- prettyPop e2
  pPrint $ intercalate " " [e1', show b, e2']
prettyExpr (AccessN s n) = pPrint $ s ++ "." ++ n
prettyExpr (AccessI s i) = pPrint $ s ++ "[" ++ show i ++ "]"
prettyExpr _ = error "Undefined Expr present! Invalid program"

-- | Pretty printing of an expr followed by a pop to use it
prettyPop :: Expr -> Printer String
prettyPop e = prettyExpr e >> pop

-- | Pretty prints a shader, which has ins, outs, & a body of expressions
-- This will be represented in an implicit 'main' function
prettyShader :: Shader -> Printer ()
prettyShader (Shader _ ins outs exprs) = do
  -- add local shader env (ins)
  prettyEnv ins
  -- add local shader env (out)
  prettyEnv outs
  -- prepare a main function for printing out
  pPrint "void main() {"
  indent
  -- evaluate all expressions inside this main shader block
  mapM_ prettyStmt exprs
  dedent
  pPrint "}"

-- | Pretty prints a FDSSL Program for one shader...
prettyProg :: (Env,Funcs,Shader) -> Printer String
prettyProg (e,funcs,s) = do
  -- add the preface
  pPrint preface
  -- add the env
  prettyEnv e
  -- add functions
  mapM_ prettyFunc (map snd funcs)
  -- add the shader core itself
  prettyShader s
  -- retrieve & show everything together
  (_,ls) <- get
  return $ intercalate "\n" $ reverse ls

-- | Runs the pretty printer over an FDSSL Program
-- produces a GLSL vertex & fragment shader
runPrettyPrinter :: Prog -> IO (String,String)
runPrettyPrinter (Prog e funcs v f) = do
  -- run for vertex shader
  (a,b) <- runStateT (prettyProg (e,funcs,v)) (None,[])
  -- run for fragment shader
  (a',b') <- runStateT (prettyProg (e,funcs,f)) (None,[])
  return (a,a')

-- | Pretty prints an FDSSL program
pretty :: Prog -> IO (String,String)
pretty p = runPrettyPrinter p
