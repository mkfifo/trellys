{-# LANGUAGE NamedFieldPuns, FlexibleContexts, ViewPatterns #-}
{-# OPTIONS_GHC -Wall -fno-warn-unused-matches #-}

-- | Utilities for managing a typechecking context.
module Language.Trellys.Environment
  (
   Env,
   UniVarBindings, Constraint(..), Constraints,
   getFlag,
   emptyEnv,
   lookupTy, lookupTyMaybe, lookupDef, lookupHint, lookupTCon, lookupDCon, getTys,
   lookupUniVar, setUniVar, setUniVars, getUniVars,
   addConstraint, getConstraints, clearConstraints,
   getDefaultTheta, withDefaultTheta, 
   getCtx, getLocalCtx, extendCtx, extendCtxs, extendCtxTele, extendCtxsGlobal,
   extendCtxMods,
   extendHints,
   extendSourceLocation, getSourceLocation, getCurrentPos,
   getDefs, substDefs,
   err, warn,
   zonk, zonkTerm, zonkTele, zonkWithBindings
  ) where

import Language.Trellys.Options
import Language.Trellys.Syntax
import Language.Trellys.PrettyPrint
import Language.Trellys.Error

import Generics.RepLib hiding (Arrow,Con,Refl)
import qualified Generics.RepLib as RL
import Language.Trellys.GenericBind hiding (avoid)

import Text.PrettyPrint.HughesPJ hiding (first)
import Text.ParserCombinators.Parsec.Pos(SourcePos)
import Control.Applicative
import Control.Monad.Reader
import Control.Monad.Error
import Control.Monad.State
import Control.Arrow(first,second)

import Data.List
import Data.Maybe (listToMaybe, catMaybes)
import Data.Map (Map)
import qualified Data.Map as M
import Text.ParserCombinators.Parsec.Pos(newPos)

-- | Environment manipulation and accessing functions
-- The context 'gamma' is a list
data Env = Env { ctx :: [ADecl],
               -- ^ elaborated term and datatype declarations.
                 globals :: Int,
               -- ^ how long the tail of "global" variables in the context is
               --    (used to supress printing those in error messages)
                 hints :: [AHint],
               -- ^ Type declarations (signatures): it's not safe to
               -- put these in the context until a corresponding term
               -- has been checked.
                 defaultTheta :: Maybe Theta,
               -- ^ used when a type needs to be FO, and no th was given
                 flags :: [Flag],
               -- ^ Command-line options that might influence typechecking
                 sourceLocation ::  [SourceLocation]
               -- ^ what part of the file we are in (for errors/warnings)
               } 
  --deriving Show

-- | Bindings of unification variables
type UniVarBindings = Map AName ATerm

-- | Outstanding constraints to be solved.
-- (eventually will make this also have equations, probably?)
data Constraint = ShouldHaveType AName ATerm
  deriving (Show)
type Constraints = [Constraint]

-- | The initial environment.
emptyEnv :: [Flag] -> Env
emptyEnv fs = Env { ctx = [] , 
                   globals = 0, 
                   hints = [],
                   defaultTheta = Nothing,
                   flags = fs, 
                   sourceLocation = [] }

instance Disp Env where
  disp e = vcat [disp decl | decl <- ctx e]

-- | Find the binding of a unification variable
lookupUniVar :: (MonadState (a,UniVarBindings) m) => AName -> m (Maybe ATerm)
lookupUniVar x = liftM (M.lookup x) (gets snd)

-- | Set the binding of a unification variable
setUniVar :: (MonadState (a,UniVarBindings) m, MonadError Err m, MonadReader Env m) => 
             AName -> ATerm -> m ()
setUniVar x a = do
  alreadyPresent <- liftM (M.member x) (gets snd)
  when alreadyPresent $ do
    old <- liftM2 (M.!) (gets snd) (return x)
    err [DS ("internal error: tried to set an already bound unification variable " ++ show x),
         DS "it had value", DD old,
         DS "and tried to set it to", DD a]
  modify (second $ M.insert x a)

-- | Set multiple unification variables at once.
setUniVars :: (MonadState (a,UniVarBindings) m, MonadError Err m, MonadReader Env m) => 
             UniVarBindings -> m ()
setUniVars bnds =
  mapM_ (uncurry setUniVar) (M.toList bnds)

getUniVars ::  (MonadState (a,UniVarBindings) m) => m UniVarBindings
getUniVars = gets snd

addConstraint ::  MonadState (Constraints,a) m => Constraint -> m ()
addConstraint c = modify (first (c:))

getConstraints :: MonadState (Constraints,a) m => m Constraints
getConstraints = gets fst

clearConstraints :: MonadState (Constraints,a) m => m ()
clearConstraints = modify (first (const []))

-- | Determine if a flag is set
getFlag :: (MonadReader Env m) => Flag -> m Bool
getFlag f = do 
 flags <- asks flags
 return (f `elem` flags)

-- return a list of all type bindings, and their names.
getTys :: (MonadReader Env m) => m [(AName,Theta,ATerm)]
getTys = do
  ctx <- asks ctx
  return $ catMaybes (map unwrap ctx)
    where unwrap (ASig v th ty) = Just (v,th,ty)
          unwrap _ = Nothing

-- | Find a name's user supplied type signature.
lookupHint   :: (MonadReader Env m) => AName -> m (Maybe (Theta,ATerm))
lookupHint v = do
  hints <- asks hints
  return $ listToMaybe [(th,ty) | AHint v' th ty <- hints, v == v']

-- | Find a name's type in the context.
lookupTyMaybe :: (MonadReader Env m, MonadError Err m) 
         => AName -> m (Maybe (Theta,ATerm))
lookupTyMaybe v = do
  ctx <- asks ctx
  return $ listToMaybe [(th,ty) | ASig  v' th ty <- ctx, v == v'] 


lookupTy :: (MonadReader Env m, MonadError Err m) 
         => AName -> m (Theta,ATerm)
lookupTy v = 
  do x <- lookupTyMaybe v
     gamma <- getLocalCtx
     case x of
       Just res -> return res
       Nothing -> err [DS ("The variable " ++ show v++ " was not found."),
                       DS "in context", DD gamma]

-- | Find a name's def in the context.
lookupDef :: (MonadReader Env m, MonadError Err m, MonadIO m) 
          => AName -> m (Maybe ATerm)
lookupDef v = do
  ctx <- asks ctx
  return $ listToMaybe [a | ADef v' a <- ctx, v == v']

-- | Find a type constructor in the context
lookupTCon :: (MonadReader Env m, MonadError Err m) 
          => AName -> m (ATelescope,Int,Maybe [AConstructorDef])
lookupTCon v = do
  g <- asks ctx
  scanGamma g
  where
    scanGamma [] = do currentEnv <- asks ctx
                      err [DS "The type constructor", DD v, DS "was not found.",
                           DS "The current environment is", DD currentEnv]
    scanGamma ((AData v' delta lev cs):g) = 
      if v == v' 
        then return $ (delta,lev,Just cs) 
        else  scanGamma g
    scanGamma ((AAbsData v' delta lev):g) =
      if v == v'
         then return $ (delta,lev,Nothing)
         else scanGamma g
    scanGamma (_:g) = scanGamma g

-- | Find a data constructor in the context
lookupDCon :: (MonadReader Env m, MonadError Err m) 
          => AName -> m (AName,ATelescope,AConstructorDef)
lookupDCon v = do
  g <- asks ctx
  scanGamma g
  where
    scanGamma [] = err [DS "The data constructor", DD v, DS "was not found."]
    scanGamma ((AData v' delta  lev cs):g) = 
        case find (\(AConstructorDef v'' tele) -> v''==v ) cs of
          Nothing -> scanGamma g
          Just c -> return $ (v', delta, c)
    scanGamma ((AAbsData v' delta lev):g) = scanGamma g
    scanGamma (_:g) = scanGamma g

-- | Extend the context with a new binding.
extendCtx :: (MonadReader Env m) => ADecl -> m a -> m a
extendCtx d =
  local (\ m@(Env {ctx = cs}) -> m { ctx = d:cs })

-- | Extend the context with a list of bindings
extendCtxs :: (MonadReader Env m) => [ADecl] -> m a -> m a
extendCtxs ds = 
  local (\ m@(Env {ctx = cs}) -> m { ctx = ds ++ cs })

-- | Extend the context with a list of bindings, marking them as "global"
extendCtxsGlobal :: (MonadReader Env m) => [ADecl] -> m a -> m a
extendCtxsGlobal ds = 
  local (\ m@(Env {ctx = cs}) -> m { ctx     = ds ++ cs,
                                     globals = length (ds ++ cs)})


-- | Extend the context with a telescope
extendCtxTele :: (MonadReader Env m) => ATelescope -> Theta -> m a -> m a
extendCtxTele AEmpty th m = m
extendCtxTele (ACons (unrebind -> ((x,unembed->ty,ep),tele))) th m = 
  extendCtx (ASig x th ty) $ extendCtxTele tele th m

-- | Extend the context with a module
extendCtxMod :: (MonadReader Env m) => AModule -> m a -> m a
extendCtxMod m k = extendCtxs (reverse $ aModuleEntries m) k -- Note we must reverse the order.

-- | Extend the context with a list of modules
extendCtxMods :: (MonadReader Env m) => [AModule] -> m a -> m a
extendCtxMods mods k = foldr extendCtxMod k mods

-- | Get the complete current context
getCtx :: MonadReader Env m => m [ADecl]
getCtx = asks ctx

-- | Get the prefix of the context that corresponds to local variables.
getLocalCtx :: MonadReader Env m => m [ADecl]
getLocalCtx = do
  g <- asks ctx
  glen <- asks globals
  return $ take (length g - glen) g

-- | Push a new source position on the location stack.
extendSourceLocation :: (MonadReader Env m, Disp t) => (Maybe SourcePos) -> t -> m a -> m a
extendSourceLocation p t = 
  local (\ e@(Env {sourceLocation = locs}) -> e {sourceLocation = (SourceLocation p t):locs})

getSourceLocation :: MonadReader Env m => m [SourceLocation]
getSourceLocation = asks sourceLocation

getCurrentPos :: MonadReader Env m => m SourcePos
getCurrentPos = do
  sourceLoc <- asks sourceLocation
  return $ case sourceLoc of
             (SourceLocation (Just p) _ : _) -> p
             _ -> newPos "unknown location" 0 0

-- | Add a type hint
extendHints :: (MonadReader Env m) => AHint -> m a -> m a
extendHints h = local (\m@(Env {hints = hs}) -> m { hints = h:hs })

-- | Manipulate the defaultTheta field
getDefaultTheta :: MonadReader Env m => m (Maybe Theta)
getDefaultTheta = asks defaultTheta

withDefaultTheta :: MonadReader Env m => Maybe Theta -> m a -> m a
withDefaultTheta dth = local (\m -> m { defaultTheta = dth })

getDefs :: MonadReader Env m => m [(AName,ATerm)]
getDefs = do
  ctx <- getCtx
  return $ filterDefs ctx
 where filterDefs ((ADef x a):ctx) = (x,a) : filterDefs ctx
       filterDefs (_:ctx) = filterDefs ctx
       filterDefs [] = []

-- | substitute all of the defs through a term
substDefs :: MonadReader Env m => ATerm -> m ATerm
substDefs tm = do
  ctx <- getCtx
  return $ substs (expandDefs ctx) tm
 where expandDefs ((ADef x a):ctx) =
           let defs = expandDefs ctx 
           in ((x, substs defs a) : defs)
       expandDefs (_:ctx) = expandDefs ctx
       expandDefs [] = []


-- Throw an error
err :: (Disp a, MonadError Err m, MonadReader Env m) => a -> m b
err d = do
  loc <- getSourceLocation
  throwError $ Err loc (disp d)

-- Print a warning
warn :: (Disp a, MonadReader Env m, MonadIO m) => a -> m ()
warn e = do
  loc <- getSourceLocation
  liftIO $ putStrLn $ "warning: " ++ render (disp (Err loc (disp e)))

----------------------------------------
-- Dealing with unification variables.
----------------------------------------

-- | To zonk a term (this word comes from GHC) means to replace all occurances of 
-- unification variables with their definitions.

zonk :: (Rep a, Applicative m, MonadState (b,UniVarBindings) m) => a -> m a
zonk a = do
  bndgs <- gets snd
  return $ zonkWithBindings bndgs a

zonkTerm :: (Applicative m, MonadState (b,UniVarBindings) m) => ATerm -> m ATerm
zonkTerm = zonk

zonkTele :: (Applicative m, MonadState (b,UniVarBindings) m) => ATelescope -> m ATelescope
zonkTele  = zonk

zonkWithBindings :: Rep a => UniVarBindings -> a -> a
zonkWithBindings bndgs = RL.everywhere (RL.mkT zonkTermOnce)
  where zonkTermOnce :: ATerm -> ATerm
        zonkTermOnce (AUniVar x ty) = case M.lookup x bndgs of
                                        Nothing -> (AUniVar x ty)
                                        Just a -> zonkWithBindings bndgs a
        zonkTermOnce a = a

