module Parser where

import Syntax
import Pretty

import Text.Parsec
import Text.Parsec.Char
import Text.Parsec.Language
import Text.Parsec.Expr
import qualified Text.Parsec.Token as P
import Debug.Trace as DT
import GHC.Float

import Data.Functor.Identity(Identity)

-- | Parser state from a program
data PState = PState {
  uniforms :: [Func], -- uniforms
  funcs    :: [Func], -- user-defined functions
  shaders  :: [(String,Shader)], -- shaders declared along the way
  progs    :: [(String,Prog)]  -- programs parsed along the way
}

initialState :: PState
initialState = PState [] [] [] []

lookupShader :: String -> Parser (Maybe Shader)
lookupShader s = do
  (PState _ _ ss _) <- getState
  return $ lookup s ss

addUni :: Func -> Parser ()
addUni u' = do
  (PState u f s p) <- getState
  putState $ PState (u':u) f s p

getUnis :: Parser ([Func])
getUnis = getState >>= return . uniforms

addFunc :: Func -> Parser ()
addFunc f' = do
  (PState u f s p) <- getState
  putState $ PState u (f':f) s p

addShader :: (String,Shader) -> Parser ()
addShader s' = do
  (PState u f s p) <- getState
  putState $ PState u f (s':s) p

addProg :: (String,Prog) -> Parser ()
addProg p' = do
  (PState u f s p) <- getState
  putState $ PState u f s (p':p)

type Parser = Parsec String (PState)

defFDSSL :: P.GenLanguageDef String u Identity
defFDSSL = (haskellStyle
  {
    P.reservedNames = [
                        "uniform",
                        "frag","vert",
                        "Int","Float","Bool","Vec2","Vec3","Vec4","Mat4","Prog",
                        "true","false",
                        "mut","const",
                        "if","then","else","for","do","set","out"],
    P.reservedOpNames = [
                          "=","*","<","<=",">",">=","==","!=","-","+","/",":",".","->"
                        ],
    P.commentStart = "/*",
    P.commentEnd = "*/",
    P.commentLine = "//"
  })

-- | Helper function for handling operators
op :: String -> (a -> a -> a) -> Assoc -> Operator String u Identity a
op s f assoc = Infix (reservedOp s *> pure f) assoc

-- BOps we have to worry about
operators :: [[Operator String u Identity (Expr)]]
operators = [
   [op "*" (BinOp Mul) AssocLeft, op "/" (BinOp Div) AssocLeft, op "%" (BinOp Mod) AssocLeft],
   [op "+" (BinOp Add) AssocLeft, op "-" (BinOp Sub) AssocLeft],
   [op "<" (BinOp Lt) AssocLeft],
   [op "<=" (BinOp Lte) AssocLeft],
   [op "==" (BinOp Eq) AssocLeft],
   [op "!=" (BinOp Neq) AssocLeft],
   [op ">=" (BinOp Gte) AssocLeft],
   [op ">" (BinOp Gt) AssocLeft]]

-- | Parse for Exprs
parseExpr :: Parser (Expr)
parseExpr = buildExpressionParser operators parseExpr'

-- | lexer w/ reserved keywods & op names
lexer :: P.GenTokenParser String u Data.Functor.Identity.Identity
lexer = P.makeTokenParser defFDSSL

-- | Identifier recognizer (lower or upper case a-z start)
lowIdentifier :: ParsecT String u Identity String
lowIdentifier = P.identifier lexer

-- | parser for whitespace
whitespace :: ParsecT String u Identity ()
whitespace = P.whiteSpace lexer

-- | Comma separated values, 2 or more
commaSep2 :: ParsecT String u Identity a -> ParsecT String u Identity [a]
commaSep2 p = (:) <$> (lexeme p <* lexeme comma) <*> commaSep1 p

-- | Comma separated values, 1 or more
commaSep1 :: ParsecT String u Identity a -> ParsecT String u Identity [a]
commaSep1 = P.commaSep1 lexer

-- | Comma separator
comma :: ParsecT String u Identity String
comma = P.comma lexer

-- | int parser
int :: ParsecT String u Identity Int
int = fromInteger <$> P.integer lexer

float :: ParsecT String u Identity Float
float = double2Float <$> P.float lexer

double :: ParsecT String u Identity Double
double = P.float lexer

lexeme :: ParsecT String u Identity a -> ParsecT String u Identity a
lexeme = P.lexeme lexer

-- | Parse reserved tokens
reserved :: String -> ParsecT String u Identity ()
reserved = P.reserved lexer

-- | Parse reserved op
reservedOp :: String -> ParsecT String u Identity ()
reservedOp = P.reservedOp lexer

-- | Parentheses recognizer
parens :: ParsecT String u Identity a -> ParsecT String u Identity a
parens = P.parens lexer

braces = P.braces lexer

brackets = P.brackets lexer

-- | Parse a type
parseType :: Parser (Type)
parseType =
  reserved "Int" *> return TI
  <|>
  reserved "Bool" *> return TB
  <|>
  reserved "Float" *> return TF
  <|>
  reserved "Vec2" *> return TV2
  <|>
  reserved "Vec3" *> return TV3
  <|>
  reserved "Vec4" *> return TV4
  <|>
  reserved "Mat4" *> return TMat4
  <|>
  reserved "Array" *> return TArray

-- | Parse a single param, used for function input
parseParam :: Parser (String,Type)
parseParam =
  do
    t <- parseType
    n <- lowIdentifier
    return (n,t)

-- | Parse several params
parseParams :: Parser ([(String,Type)])
parseParams = parens $ commaSep2 $ parseParam

-- | Parse a uniform
parseUniform :: Parser ()
parseUniform =
  do
    DT.traceM "parsing uniform..."
    whitespace
    reserved "uniform"
    typ <- parseType
    DT.traceM $ "uni type " ++ (show typ)
    name <- lowIdentifier
    DT.traceM $ "uni name " ++ name
    let u = Func name [] typ Uniform
    -- add uniform to state
    addUni u
    return ()

-- | Parse a function signature
parseFuncSignature :: Parser ([(String,Type)],Type)
parseFuncSignature =
  -- (t,t,) -> t
  do
    params <- parseParams
    reservedOp "->"
    t <- parseType
    return (params,t)
  <|>
  -- t -> t
  do
    p <- parseParam
    reservedOp "->"
    t <- parseType
    return ([p],t)
  <|>
  -- t
  do
    t <- parseType
    return ([],t)

parseShaderSignature :: Parser ([(String,Type)],[(String,Type)])
parseShaderSignature =
  do
    t1 <- (try parseParams <|> do {parseParam >>= \z -> return [z]} <|> string "()" *> return [])
    whitespace
    DT.traceM $ "T1 obtained as" ++ show t1
    reservedOp "->"
    whitespace
    t2 <- (try parseParams <|> do {parseParam >>= \z -> return [z]} <|> string "()" *> return [])
    DT.traceM $ "T2 obtained as" ++ show t2
    return (t1,t2)

parseBOp :: Parser (BOp)
parseBOp =
  reserved "+" *> return Add
  <|>
  reserved "-" *> return Sub
  <|>
  reserved "*" *> return Mul
  <|>
  reserved "/" *> return Div
  <|>
  reserved "%" *> return Mod
  <|>
  reserved "&&" *> return And
  <|>
  reserved "||" *> return Or
  <|>
  reserved "==" *> return Eq
  <|>
  reserved "!=" *> return Neq
  <|>
  reserved ">=" *> return Gte
  <|>
  reserved ">" *> return Gt
  <|>
  reserved "<=" *> return Lte
  <|>
  reserved "<" *> return Lt
  -- TODO no bitwise ops in here yet

-- | Parse an expr
parseExpr' :: Parser (Expr)
parseExpr' =
  DT.trace "parsing expression..." $
  Mut <$> (reserved "mut" *> parseType) <*> lowIdentifier <*> (reserved "=" *> parseExpr) <*> parseExpr
  <|>
  Const <$> (reserved "const" *> parseType) <*> lowIdentifier <*> (reserved "=" *> parseExpr) <*> parseExpr
  <|>
  Update <$> (reserved "set" *> lowIdentifier) <*> parseExpr <*> parseExpr
  <|>
  Out <$> (reserved "out" *> lowIdentifier) <*> parseExpr <*> parseExpr
  <|>
  Branch <$> (reserved "if" *> parseExpr) <*> (reserved "then" *> (reserved "{" *> parseExpr <* reserved "}")) <*> (reserved "else" *> (reserved "{" *> parseExpr <* reserved "}"))
  <|>
  For <$> (reserved "for" *> parseExpr) <*> (reserved "do" *> return Nothing) <*> (reserved "{" *> parseExpr <* reserved "}") <*> parseExpr
  -- <|>
  -- SComment <$> (string "//" *> manyTill anyChar newline) <*> parseExpr
  -- <|>
  -- BComment <$> (string "/*" *> manyTill anyChar (try (string "*/"))) <*> parseExpr
  -- -- sequence will never be used in concrete syntax
  <|>
  F <$> try float
  <|>
  D <$> try double
  <|>
  I <$> int
  <|>
  B <$> (reserved "true" *> return True)
  <|>
  B <$> (reserved "false" *> return False)
  <|>
  do
    DT.traceM "parsing vec4..."
    reserved "vec4"
    e1 <- parseExpr
    whitespace
    e2 <- parseExpr
    whitespace
    e3 <- parseExpr
    whitespace
    e4 <- parseExpr
    return $ V4 (e1,e2,e3,e4)
  <|>
  do
    DT.traceM "parsing vec3..."
    reserved "vec3"
    e1 <- parseExpr
    whitespace
    e2 <- parseExpr
    whitespace
    e3 <- parseExpr
    return $ V3 (e1,e2,e3)
  <|>
  do
    DT.traceM "parsing vec2..."
    reserved "vec2"
    e1 <- parseExpr
    spaces
    e2 <- parseExpr
    return $ V2 (e1,e2)
  -- -- TODO add Mat4, but realizing some names may need to be looked up to get their types...
  <|>
  DT.trace "trying array..." (Array <$> (brackets (commaSep1 parseExpr)))
  <|>
  try (
    do
      DT.traceM "Trying App..."
      i <- lowIdentifier
      es <- parens (many1 parseExpr)
      DT.traceM $ "App name is " ++ i
      DT.traceM $ "App list is " ++ (show es)
      e <- parseExpr
      return $ App i es e
  )
  --try (App <$> lowIdentifier <*> parens (commaSep1 parseExpr) <*> return NOp)
  <|>
  DT.trace "trying accessI..." try (AccessI <$> lowIdentifier <*> (brackets int))
  <|>
  DT.trace "trying accessN..." try (AccessN <$> lowIdentifier <*> (brackets lowIdentifier))
  <|>
  DT.trace "trying ref..." (try (Ref <$> (lowIdentifier <* notFollowedBy (reserved "[" <|> reserved "("))))
  <|>
  parens (parseExpr <* notFollowedBy comma) -- expr wrapped in parens, which is ok, but not part of list of sorts...
  <|>
  DT.trace "checking NOp..." (lookAhead (try $ reservedOp "}") *> return NOp) -- Nop is used to cap off when there's nothing else left here...
  -- -- <|>
  -- -- important that this goes LAST, otherwise binops will infinitely evaluate exprs forever...
  -- do
  --   DT.traceM "parsing BinOp"
  --   e1 <- parseExpr
  --   bo <- parseBOp
  --   e2 <- parseExpr
  --   return $ BinOp bo e1 e2
  -- TODO Float goes here too

-- | Parse a function
parseFunc :: Parser ()
parseFunc =
  do
    DT.traceM "parsing function"
    whitespace
    name <- lowIdentifier
    DT.traceM $ "identifier is " ++ name
    reservedOp ":"
    (params,typ) <- parseFuncSignature
    DT.traceM $ "Func signature parts are " ++ show params ++ " and " ++ show typ
    reservedOp "="
    reservedOp "{"
    expr <- parseExpr
    reservedOp "}"
    let f = Func name params typ (Body expr "")
    -- update the state with this function
    addFunc f
    return ()

-- | Convert a pair of name & type (a param), to a func for internal rep
toVarying :: (String,Type) -> Func
toVarying (s,t) = Func s [] t Varying

parseShader :: Parser ()
parseShader = try $ do
  DT.traceM "parsing shader..."
  t <- ((reserved "vert" *> return VertShader) <|> (reserved "frag" *> return FragShader))
  DT.traceM $ "Shader type is " ++ (show t)
  n <- lowIdentifier
  DT.traceM $ "Shader name <<>> is " ++ n
  reservedOp ":"
  (e1,e2) <- parseShaderSignature
  DT.traceM $ "Shader signature parsed, " ++ show e1 ++ show e2
  whitespace
  reservedOp "="
  e <- braces parseExpr
  DT.traceM $ "Expr parsed as " ++ show e
  let shader = Shader t (map toVarying e1) (map toVarying e2) e
  -- add this shader to the env
  addShader (n,shader)
  return ()

-- | special composition parsing
parseCompShader :: Parser ()
parseCompShader = try $ do
  DT.traceM "parsing shader..."
  t <- ((reserved "vert" *> return VertShader) <|> (reserved "frag" *> return FragShader))
  DT.traceM $ "Shader type is " ++ (show t)
  n <- lowIdentifier
  DT.traceM $ "Shader name is " ++ n
  reservedOp ":"
  (e1,e2) <- parseShaderSignature
  DT.traceM $ "Shader signature parsed, " ++ show e1 ++ show e2
  whitespace
  reservedOp "="
  s1 <- lowIdentifier
  reservedOp "."
  s2 <- lowIdentifier
  --let shader = Shader t (map toVarying e1) (map toVarying e2) e
  -- add this shader to the env
  (Just s1') <- lookupShader s1
  (Just s2') <- lookupShader s2
  case comp s2' s1' of
    (Just q) -> do
      addShader (n,q)
      return ()
    Nothing  -> unexpected "bad shader comp"

-- | Get the inputs to this shader (attributes or varyings)
getInputs :: Shader -> Env
getInputs (Shader _ e _ _) = e

-- parse a single program
parseProgram :: Parser ()
parseProgram = try $ do
  DT.traceM "parsing program..."
  n <- lowIdentifier
  reservedOp ":"
  reserved "Prog"
  reservedOp "="
  reserved "mkProg"
  -- get the names of the vertex & fragment shaders
  v <- lowIdentifier
  f <- lowIdentifier
  -- try to lookup these shaders, and build a program if possible
  (Just vs) <- lookupShader v
  (Just fs) <- lookupShader f
  unis <- getUnis
  let p = Prog unis (getInputs vs) vs fs
  -- add a named program to the env
  addProg (n,p)
  return ()
  --  (_,_) -> unexpected $ "Could not find vertex or fragment shader for program " ++ n

-- parse an entire FDSSL script, and return the programs it produced
parseFDSSL :: Parser ([(String,Prog)])
parseFDSSL =
  many (choice [parseProgram,parseUniform,parseFunc,parseShader,parseCompShader]) >> getState >>= return . progs
  -- parseProgram,parseUniform,parseFunc,parseShader,whitespace

parseFDSSLFile :: String -> IO (Either ParseError ([(String,Prog)]))
parseFDSSLFile f = do
  c <- readFile f
  DT.traceM "starting parse..."
  return $ runParser (parseFDSSL <* eof) initialState f c
