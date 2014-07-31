{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NoMonomorphismRestriction  #-}
{-# LANGUAGE TypeSynonymInstances       #-}  
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ParallelListComp           #-}
{-# LANGUAGE OverloadedStrings          #-}

-- | This module contains the functions that convert /from/ descriptions of 
-- symbols, names and types (over freshly parsed /bare/ Strings),
-- /to/ representations connected to GHC vars, names, and types.
-- The actual /representations/ of bare and real (refinement) types are all
-- in `RefType` -- they are different instances of `RType`

module Language.Haskell.Liquid.Bare (
    GhcSpec (..)
  , makeGhcSpec
  ) where

import ConLike                  
import GHC hiding               (lookupName, Located)
import Text.PrettyPrint.HughesPJ    hiding (first, (<>))
import Var
import Name                     (getSrcSpan, isInternalName)
import NameSet
import Id                       (isConLikeId)
import PrelNames
import PrelInfo                 (wiredInThings)
import Type                     (expandTypeSynonyms, splitFunTy_maybe)
import DataCon                  (dataConWorkId, dataConStupidTheta)
import TyCon                    (SynTyConRhs(SynonymTyCon))
import HscMain
import TysWiredIn
import BasicTypes               (TupleSort (..), Arity)
import TcRnDriver               (tcRnLookupRdrName) 
import RdrName                  (setRdrNameSpace)
import OccName                  (tcName)
import Data.Char                (isLower, isUpper)
import Text.Printf
-- import Data.Maybe               (listToMaybe, fromMaybe, mapMaybe, catMaybes, isNothing, fromJust)
import Control.Monad.State      (get, gets, modify, State, evalState, evalStateT, execState, StateT)
import Data.Traversable         (forM)
import Control.Applicative      ((<$>), (<*>), (<|>))
import Control.Monad.Reader     hiding (forM)
import Control.Monad.Error      hiding (Error, forM)
import Control.Monad.Writer     hiding (forM)
import qualified Control.Exception as Ex 
import Data.Bifunctor
-- import Data.Data                hiding (TyCon, tyConName)
-- import Data.Function            (on)
import qualified Data.Text as T
import Text.Parsec.Pos
import Language.Fixpoint.Misc
import Language.Fixpoint.Names                  (prims, hpropConName, propConName, takeModuleNames, dropModuleNames, isPrefixOfSym, dropSym, lengthSym, headSym, stripParensSym)
import Language.Fixpoint.Types                  hiding (Def, Predicate, R)
import Language.Fixpoint.Sort                   (checkSortFull, checkSortedReftFull, checkSorted)
import Language.Haskell.Liquid.GhcMisc          hiding (L)
import Language.Haskell.Liquid.Misc
import Language.Haskell.Liquid.Types
import Language.Haskell.Liquid.RefType
import Language.Haskell.Liquid.Errors
-- import Language.Haskell.Liquid.PrettyPrint
import Language.Haskell.Liquid.PredType hiding (unify)
import qualified Language.Haskell.Liquid.Measure as Ms


import Data.Maybe
import qualified Data.List           as L
import qualified Data.HashSet        as S
import qualified Data.HashMap.Strict as M
import TypeRep

import Debug.Trace (trace)

------------------------------------------------------------------
---------- Top Level Output --------------------------------------
------------------------------------------------------------------

makeGhcSpec :: Config -> ModName -> [Var] -> [Var] -> NameSet -> HscEnv
            -> [(ModName,Ms.BareSpec)]
            -> IO GhcSpec
makeGhcSpec cfg name vars defVars exports env specs
  = throwOr (throwOr return . checkGhcSpec specs) =<< execBare act initEnv
  where
    act     = makeGhcSpec' cfg vars defVars exports specs
    throwOr = either Ex.throw
    initEnv = BE name mempty mempty mempty env

checkMeasures emb env = concatMap (checkMeasure emb env)

checkMeasure :: M.HashMap TyCon FTycon -> SEnv SortedReft -> Measure SpecType DataCon -> [Error]
checkMeasure emb γ (M name@(Loc src n) sort body)
  = [txerror e | Just e <- checkMBody γ emb name sort <$> body]
  where 
    txerror = ErrMeas (sourcePosSrcSpan src) n

checkMBody γ emb name sort (Def s c bs body) = go γ' body
  where 
    γ'  = foldl (\γ (x, t) -> insertSEnv x t γ) γ xts
    xts = zip bs $ rTypeSortedReft emb . subsTyVars_meet su <$> (ty_args trep)
    ct  = ofType $ dataConUserType c :: SpecType
    su  = unify (ty_res trep) (head $ snd3 $ bkArrowDeep sort)


    trep = toRTypeRep ct
    unify (RVar tv _) t                    = [(tv, toRSort t, t)]
    unify (RApp _ ts _ _) (RApp _ ts' _ _) = concat $ zipWith unify ts ts'
    unify _ _                              = []

    go γ (E e)   = checkSortFull γ rs e
    go γ (P p)   = checkSortFull γ psort p
    go γ (R s p) = checkSortFull (insertSEnv s sty γ) psort p

    sty = rTypeSortedReft emb sort' -- (thd3 $ bkArrowDeep sort)
    rs  = rTypeSort       emb sort' -- (thd3 $ bkArrowDeep sort)

    psort = FApp propFTyCon []
    sort' = fromRTypeRep $ trep' 
                  { ty_vars = [], ty_preds = [], ty_labels = []
                  , ty_binds = tail $ ty_binds trep'
                  , ty_args = (tail $ ty_args trep')}

    trep' = toRTypeRep sort



------------------------------------------------------------------------------------------------
makeGhcSpec' :: Config -> [Var] -> [Var] -> NameSet -> [(ModName,Ms.BareSpec)] -> BareM GhcSpec
------------------------------------------------------------------------------------------------
makeGhcSpec' cfg vars defVars exports specs
  = do name <- gets modName
       makeRTEnv (concat [(mod,) <$> Ms.aliases  sp | (mod, sp) <- specs])
                 (concat [(mod,) <$> Ms.paliases sp | (mod, sp) <- specs])
       (tcs, dcs)      <- mconcat <$> mapM makeConTypes specs
       let (tcs', dcs') = wiredTyDataCons
       let tycons       = tcs ++ tcs'
       let datacons     = concat dcs ++ dcs'
       let dcSelectors  = concat $ map makeMeasureSelectors (concat dcs)
       modify $ \be -> be { tcEnv = makeTyConInfo tycons }
       measures'       <- mconcat <$> mapM makeMeasureSpec specs
       let measures     = measures' `mappend` Ms.mkMSpec' dcSelectors
       let (cs, ms)     = makeMeasureSpec' measures
       let cms          = makeClassMeasureSpec measures
       sigs'           <- mconcat <$> mapM (makeAssertSpec name cfg vars defVars) specs
       asms'           <- mconcat <$> mapM (makeAssumeSpec name cfg vars defVars) specs
       invs            <- mconcat <$> mapM makeInvariants specs
       ialias          <- mconcat <$> mapM makeIAliases   specs
       embs            <- mconcat <$> mapM makeTyConEmbeds specs
       targetVars      <- makeTargetVars name defVars $ binders cfg
       (cls, mts)      <- second mconcat . unzip . mconcat
                          <$> mapM (makeClasses cfg vars) specs
       let dms          = makeDefaultMethods vars mts
       tcEnv           <- gets tcEnv
       let sigs         = [ (x, (txRefSort tcEnv embs . txExpToBind) <$> t)
                          | (m, x, t) <- sigs'++mts++dms ]
       let asms         = [ (x, (txRefSort tcEnv embs . txExpToBind) <$> t)
                          | (m, x, t) <- asms' ]

       let cs'          = -- mapSnd (Loc dummyPos . txRefSort tcEnv embs) <$> meetDataConSpec cs ((mapSnd val <$> datacons) ++ cls)
                          [ (v, Loc (getSourcePos v) (txRefSort tcEnv embs t)) | (v, t) <- meetDataConSpec cs ((mapSnd val <$> datacons) ++ cls)]
       let cms'         = [ (x, Loc l $ cSort t) | (Loc l x, t) <- cms ]
       let ms'          = [ (x, Loc l t) | (Loc l x, t) <- ms, isNothing $ lookup x cms' ]
       syms            <- makeSymbols (vars ++ map fst cs') (map fst ms) (sigs ++ asms ++ cs') ms' (invs ++ (snd <$> ialias))
       let su           = mkSubst [ (x, mkVarExpr v) | (x, v) <- syms]
       let tx           = subsFreeSymbols su
       let txi          = subsFreeSymbolsInv su
       let txia         = subsFreeSymbolsIAliases su
       let txq          = subsFreeSymbolsQual su
       let syms'        = [(symbol v, v) | (_, v) <- syms]
       decr'           <- mconcat <$> mapM (makeHints defVars) specs
       texprs'         <- mconcat <$> mapM (makeTExpr defVars) specs

       lazies          <- S.fromList . mconcat
                                    <$> sequence [ makeLazy defVars (mod,spec)
                                                 | (mod,spec) <- specs
                                                 , mod == name
                                                 ]

       lvars'          <- S.fromList . mconcat
                                    <$> sequence [ makeLVars defVars (mod,spec)
                                                 | (mod,spec) <- specs
                                                 , mod == name
                                                 ]
       quals           <- mconcat <$> mapM makeQualifiers specs
       let renamedSigs = renameTyVars <$> tx sigs
           pluggedSigs = [ (x, plugHoles r τ <$> t)
                         | (x, t) <- renamedSigs
                         , let τ = expandTypeSynonyms $ varType x
                         , let r = maybeTrue x name exports]
           renamedAsms = renameTyVars <$> tx asms
           -- pluggedAsms = [ (x, plugHoles r τ <$> t)
           --               | (x, t) <- renamedSigs
           --               , let τ = expandTypeSynonyms $ varType x
           --               , let r = maybeTrue x name exports]
       return          $ SP { tySigs     = pluggedSigs
                            , asmSigs    = renamedAsms
                            , ctors      = tx cs'
                            , meas       = tx (ms' ++ varMeasures vars ++ cms')
                            , invariants = txi invs
                            , ialiases   = txia ialias
                            , dconsP     = mapSnd val <$> datacons
                            , tconsP     = tycons
                            , freeSyms   = syms'
                            , tcEmbeds   = embs
                            , qualifiers = txq quals
                            , decr       = decr'
                            , texprs     = texprs'
                            , lvars      = lvars'
                            , lazy       = lazies
                            , tgtVars    = targetVars
                            , config     = cfg
                            , exports    = exports
                            , measures   = subst su <$> M.elems $ Ms.measMap measures
                            , tyconEnv   = tcEnv
                            }

makeMeasureSelectors :: (DataCon, Located DataConP) -> [Measure SpecType DataCon]
makeMeasureSelectors (dc, (Loc loc (DataConP _ vs _ _ _ xts r))) = go <$> (zip (reverse xts) [1..])
  where go ((x,t), i) = makeMeasureSelector (Loc loc x) (dty t) dc n i
        
        dty t = foldr RAllT  (RFun dummySymbol r (fmap mempty t) mempty) vs
        n     = length xts

makeMeasureSelector x s dc n i = M {name = x, sort = s, eqns = [eqn]}
  where eqn   = Def x dc (mkx <$> [1 .. n]) (E (EVar $ mkx i)) 
        mkx j = symbol ("xx" ++ show j)
        
--- Refinement Type Aliases
makeRTEnv rts pts  = do initRTEnv
                        makeRPAliases pts
                        makeRTAliases rts
  where initRTEnv  = do forM_ rts $ \(mod, rta) -> setRTAlias (rtName rta) $ Left (mod, rta)
                        forM_ pts $ \(mod, pta) -> setRPAlias (rtName pta) $ Left (mod, pta)


makeRTAliases xts = mapM_ expBody xts
  where expBody (mod,xt) = inModule mod $ do
                             let l = rtPos xt
                             body <- withVArgs l (rtVArgs xt) $ expandRTAlias l $ rtBody xt
                             setRTAlias (rtName xt) $ Right $ mapRTAVars symbolRTyVar $ xt { rtBody = body }

makeRPAliases xts     = mapM_ expBody xts
  where 
    expBody (mod, xt) = inModule mod $ do
                          let l = rtPos xt
                          env  <- gets $ predAliases . rtEnv
                          body <- withVArgs l (rtVArgs xt) $ expandRPAliasE l $ rtBody xt
                          setRPAlias (rtName xt) $ Right $ xt { rtBody = body }

-- | Using the Alias Environment to Expand Definitions
expandRTAliasMeasure m
  = do eqns <- sequence $ expandRTAliasDef <$> (eqns m)
       return $ m { sort = generalize (sort m)
                  , eqns = eqns }

expandRTAliasDef :: Def LocSymbol -> BareM (Def LocSymbol)
expandRTAliasDef d
  = do env <- gets rtEnv
       body <- expandRTAliasBody (loc $ measure d) env $ body d
       return $ d { body = body }

expandRTAliasBody :: SourcePos -> RTEnv -> Body -> BareM Body
expandRTAliasBody l env (P p)   = P   <$> (expPAlias l p)
expandRTAliasBody l env (R x p) = R x <$> (expPAlias l p)
expandRTAliasBody l _   (E e)   = E   <$> resolve l e

expPAlias :: SourcePos -> Pred -> BareM Pred
expPAlias l = expandPAlias l []


expandRTAlias   :: SourcePos -> BareType -> BareM SpecType
expandRTAlias l bt = expType =<< expReft bt
  where 
    expReft      = mapReftM (txPredReft expPred)
    expType      = expandAlias  l []
    expPred      = expandPAlias l []

txPredReft :: (Pred -> BareM Pred) -> RReft -> BareM RReft
txPredReft f (U r p l) = (\r -> U r p l) <$> txPredReft' f r
  where 
    txPredReft' f (Reft (v, ras)) = Reft . (v,) <$> mapM (txPredRefa f) ras
    txPredRefa  f (RConc p)       = RConc <$> f p
    txPredRefa  _ z               = return z

-- | Using the Alias Environment to Expand Definitions

expandRPAliasE l = expandPAlias l []

expandAlias :: SourcePos -> [Symbol] -> BareType -> BareM SpecType
expandAlias l = go
  where
    go s t@(RApp (Loc _ c) _ _ _)
      | c `elem` s = Ex.throw $ errOther $ text 
                              $ "Cyclic Reftype Alias Definition: " ++ show (c:s)
      | otherwise  = lookupExpandRTApp l s t
    go s (RVar a r)       = RVar (symbolRTyVar a) <$> resolve l r
    go s (RFun x t t' r)  = rFun x <$> go s t <*> go s t'
    go s (RAppTy t t' r)  = RAppTy <$> go s t <*> go s t' <*> resolve l r
    go s (RAllE x t1 t2)  = liftM2 (RAllE x) (go s t1) (go s t2)
    go s (REx x t1 t2)    = liftM2 (REx x) (go s t1) (go s t2)
    go s (RAllT a t)      = RAllT (symbolRTyVar a) <$> go s t
    go s (RAllP a t)      = RAllP <$> ofBPVar a <*> go s t
    go s (RAllS l t)      = RAllS l <$> go s t
    go s (RCls c ts)      = RCls <$> lookupGhcClass c <*> mapM (go s) ts
    go _ (ROth s)         = return $ ROth s
    go _ (RExprArg e)     = return $ RExprArg e
    go _ (RHole r)        = RHole <$> resolve l r


lookupExpandRTApp l s (RApp lc@(Loc _ c) ts rs r) = do
  env <- gets (typeAliases.rtEnv)
  case M.lookup c env of
    Just (Left (mod,rtb)) -> do
      st <- inModule mod $ withVArgs l (rtVArgs rtb) $ expandAlias l (c:s) $ rtBody rtb
      let rts = mapRTAVars symbolRTyVar $ rtb { rtBody = st }
      setRTAlias c $ Right rts
      r' <- resolve l r
      expandRTApp l s rts ts r'
    Just (Right rts) -> do
      r' <- resolve l r
      withVArgs l (rtVArgs rts) $ expandRTApp l s rts ts r'
    Nothing
      | isList c && length ts == 1 -> do
        tyi <- tcEnv <$> get
        r'  <- resolve l r
        liftM2 (bareTCApp tyi r' listTyCon) (mapM (go s) rs) (mapM (expandAlias l s) ts)
      | isTuple c -> do
        tyi <- tcEnv <$> get
        r'  <- resolve l r
        let tc = tupleTyCon BoxedTuple (length ts)
        liftM2 (bareTCApp tyi r' tc) (mapM (go s) rs) (mapM (expandAlias l s) ts)
      | otherwise -> do
        tyi <- tcEnv <$> get
        r'  <- resolve l r
        liftM3 (bareTCApp tyi r') (lookupGhcTyCon lc) (mapM (go s) rs) (mapM (expandAlias l s) ts)
  where
    go s (RPropP ss r) = RPropP <$> mapM ofSyms ss <*> resolve l r
    go s (RProp ss t)  = RProp <$> mapM ofSyms ss <*> expandAlias l s t
    go _ (RHProp _ _)  = errorstar "TODO:EFFECTS:lookupExpandRTApp"

expandRTApp :: SourcePos -> [Symbol] -> RTAlias RTyVar SpecType  -> [BareType] -> RReft -> BareM SpecType
expandRTApp l s rta args r
  | length args == (length αs) + (length εs)
  = do args'  <- mapM (expandAlias l s) args
       let ts  = take (length αs) args'
           αts = zipWith (\α t -> (α, toRSort t, t)) αs ts
       return $ subst su . (`strengthen` r) . subsTyVars_meet αts $ rtBody rta
  | otherwise
  = errortext $ (text msg)
  where
    su        = mkSubst $ zip (symbol <$> εs) es
    αs        = rtTArgs rta 
    εs        = rtVArgs rta
--    msg       = rtName rta ++ " " ++ join (map showpp args)
    es_       = drop (length αs) args
    es        = map (exprArg msg) es_
    msg = "Malformed type alias application at " ++ show l ++ "\n\t"
               ++ show (rtName rta) 
               ++ " defined at " ++ show (rtPos rta)
               ++ "\n\texpects " ++ show (length αs + length εs)
               ++ " arguments but it is given " ++ show (length args)
-- | exprArg converts a tyVar to an exprVar because parser cannot tell 
-- HORRIBLE HACK To allow treating upperCase X as value variables X
-- e.g. type Matrix a Row Col = List (List a Row) Col

exprArg _   (RExprArg e)     
  = e
exprArg _   (RVar x _)       
  = EVar (symbol x)
exprArg _   (RApp x [] [] _) 
  = EVar (symbol x)
exprArg msg (RApp f ts [] _) 
  = EApp (symbol <$> f) (exprArg msg <$> ts)
exprArg msg (RAppTy (RVar f _) t _)   
  = EApp (dummyLoc $ symbol f) [exprArg msg t]
exprArg msg z 
  = errorstar $ printf "Unexpected expression parameter: %s in %s" (show z) msg 

expandPAlias :: SourcePos -> [Symbol] -> Pred -> BareM Pred
expandPAlias l = go
  where 
    go s p@(PBexp (EApp f@(Loc l' f') es))
      | f' `elem` s                = errorstar $ "Cyclic Predicate Alias Definition: " ++ show (f':s)
      | otherwise = do
          env <- gets (predAliases.rtEnv)
          case M.lookup f' env of
            Just (Left (mod,rp)) -> do
              body <- inModule mod $ withVArgs l' (rtVArgs rp) $ expandPAlias l' (f':s) $ rtBody rp
              let rp' = rp { rtBody = body }
              setRPAlias f' $ Right $ rp'
              expandRPApp l (f':s) rp' <$> resolve l es
            Just (Right rp) ->
              withVArgs l (rtVArgs rp) (expandRPApp l (f':s) rp <$> resolve l es)
            Nothing -> fmap PBexp (EApp <$> resolve l f <*> resolve l es)
    go s (PAnd ps)                = PAnd <$> (mapM (go s) ps)
    go s (POr  ps)                = POr  <$> (mapM (go s) ps)
    go s (PNot p)                 = PNot <$> (go s p)
    go s (PImp p q)               = PImp <$> (go s p) <*> (go s q)
    go s (PIff p q)               = PIff <$> (go s p) <*> (go s q)
    go s (PAll xts p)             = PAll xts <$> (go s p)
    go _ p                        = resolve l p

expandRPApp l s rp es
  = let su  = mkSubst $ safeZipWithError msg (rtVArgs rp) es
        msg = "Malformed alias application at " ++ show l ++ "\n\t"
               ++ show (rtName rp) 
               ++ " defined at " ++ show (rtPos rp)
               ++ "\n\texpects " ++ show (length $ rtVArgs rp)
               ++ " arguments but it is given " ++ show (length es)
--        msg = "expandRPApp: " ++ show (EApp (dummyLoc $ symbol $ rtName rp) es)
    in subst su $ rtBody rp


makeQualifiers (mod,spec) = inModule mod mkQuals
  where
    mkQuals = -- resolve dummyPos $ Ms.qualifiers spec
              mapM (\q -> resolve (q_pos q) q) $ Ms.qualifiers spec


makeClasses cfg vs (mod, spec) = inModule mod $ mapM mkClass $ Ms.classes spec
  where
    --FIXME: cleanup this code
    unClass = snd . bkClass . fourth4 . bkUniv
    mkClass (RClass c ss as ms)
            = do let l   = loc c  
                 tc  <- lookupGhcTyCon c
                 ss' <- mapM (mkSpecType l) ss
                 let (dc:_) = tyConDataCons tc
                 let αs  = map symbolRTyVar as
                 let as' = [rVar $ symbolTyVar a | a <- as ]
                 let ms' = [ (s, rFun "" (RCls c (flip RVar mempty <$> as)) t) | (s, t) <- ms]
                 vts <- makeSpec cfg vs ms'
                 let sts = [(val s, unClass $ val t) | (s, _)    <- ms
                                                     | (_, _, t) <- vts]
                 let t   = RCls (fromJust $ tyConClass_maybe tc) as'
                 let dcp = DataConP l αs [] [] ss' (reverse sts) t
                 return ((dc,dcp),vts)

makeHints vs (_,spec) = varSymbols id "Hint" vs $ Ms.decr spec
makeLVars vs (_,spec) = fmap fst <$> (varSymbols id "LazyVar" vs $ [(v, ()) | v <- Ms.lvars spec])
makeLazy  vs (_,spec) = fmap fst <$> (varSymbols id "Lazy" vs $ [(v, ()) | v <- S.toList $ Ms.lazy spec])
makeTExpr vs (_,spec) = varSymbols id "TermExpr" vs $ Ms.termexprs spec

varSymbols :: ([Var] -> [Var]) -> Symbol ->  [Var] -> [(LocSymbol, a)] -> BareM [(Var, a)]
varSymbols f n vs  = concatMapM go
  where lvs        = M.map L.sort $ group [(sym v, locVar v) | v <- vs]
        sym        = dropModuleNames . symbol . showPpr
        locVar v   = (getSourcePos v, v)
        go (s, ns) = case M.lookup (val s) lvs of 
                     Just lvs -> return ((, ns) <$> varsAfter f s lvs)
                     Nothing  -> ((:[]).(,ns)) <$> lookupGhcVar s
        msg s      = printf "%s: %s for Undefined Var %s"
                         (symbolString n) (show (loc s)) (show (val s))

varsAfter f s lvs 
  | eqList (fst <$> lvs)
  = f (snd <$> lvs)
  | otherwise
  = map snd $ takeEqLoc $ dropLeLoc lvs
  where takeEqLoc xs@((l, _):_) = L.takeWhile ((l==) . fst) xs
        takeEqLoc []            = []
        dropLeLoc               = L.dropWhile ((loc s >) . fst)
        eqList []               = True
        eqList (x:xs)           = all (==x) xs

txRefSort env embs = mapBot (addSymSort embs env)

addSymSort embs tcenv t@(RApp rc@(RTyCon c _ _) ts rs r) 
  = RApp rc ts (zipWith addSymSortRef ps rargs) r'
  where
    ps                 = rTyConPVs $ appRTyCon embs tcenv rc ts
    (rargs,rrest)      = splitAt (length ps) rs
    r'                 = L.foldl' go r rrest
    go r (RPropP _ r') = r' `meet` r
    go _ (RHProp _ _ ) = errorstar "TODO:EFFECTS:addSymSort"
    go r _             = r

addSymSort _ _ t 
  = t

addSymSortRef _ (RHProp _ _)   = errorstar "TODO:EFFECTS:addSymSortRef"
addSymSortRef p r | isPropPV p = addSymSortRef' p r 
                  | otherwise  = errorstar "addSymSortRef: malformed ref application"


addSymSortRef' p (RProp s (RVar v r)) | isDummy v
  = RProp xs t
    where
      t  = ofRSort (pvType p) `strengthen` r
      xs = spliceArgs "addSymSortRef 1" s p
           -- safeZip "addSymSortRef 1" (fst <$> s) (fst3 <$> pargs p)

addSymSortRef' p (RProp s t) 
  = RProp xs t
    where
      xs = spliceArgs "addSymSortRef 2" s p
           --  safeZip "addSymSortRef 2" (fst <$> s) (fst3 <$> pargs p)
      
addSymSortRef' p (RPropP s r@(U _ (Pr [up]) _)) 
  = RPropP xs r
    where
      xs = safeZip "addRefSortMono" (snd3 <$> pargs up) (fst3 <$> pargs p)

addSymSortRef' p (RPropP s t)
  = RPropP s t

spliceArgs msg s p = safeZip msg (fst <$> s) (fst3 <$> pargs p) 



varMeasures vars  = [ (symbol v, varSpecType v) 
                    | v <- vars
                    , isDataConWorkId v
                    , isSimpleType $ varType v
                    ]

varSpecType v      = Loc (getSourcePos v) (ofType $ varType v)


isSimpleType t = null tvs && isNothing (splitFunTy_maybe tb)
  where (tvs, tb) = splitForAllTys t 
-------------------------------------------------------------------------------
-- Renaming Type Variables in Haskell Signatures ------------------------------
-------------------------------------------------------------------------------

-- This throws an exception if there is a mismatch
-- renameTyVars :: (Var, SpecType) -> (Var, SpecType)
renameTyVars (x, lt@(Loc l t)) = (x, Loc l $ mkUnivs (rTyVar <$> αs) [] [] t')
  where
    t'                     = subts su $ mkUnivs [] ps ls tbody
    su                     = [(y, rTyVar x) | (x, y) <- tyvsmap]
    tyvsmap                = vmap $ execState (mapTyVars τbody tbody) initvmap 
    initvmap               = initMapSt err
    (αs, τbody)            = splitForAllTys $ expandTypeSynonyms $ varType x
    (as, ps, ls, tbody)    = bkUniv t
    err                    = errTypeMismatch x lt


data MapTyVarST = MTVST { vmap   :: [(Var, RTyVar)]
                        , errmsg :: Error 
                        }

initMapSt = MTVST []

mapTyVars :: (PPrint r, Reftable r) => Type -> RRType r -> State MapTyVarST ()
mapTyVars τ (RAllT a t)   
  = mapTyVars τ t
mapTyVars (ForAllTy α τ) t 
  = mapTyVars τ t
mapTyVars (FunTy τ τ') (RFun _ t t' _) 
   = mapTyVars τ t  >> mapTyVars τ' t'
mapTyVars (TyConApp _ τs) (RApp _ ts _ _) 
   = zipWithM_ mapTyVars τs ts
mapTyVars (TyVarTy α) (RVar a _)      
   = modify $ \s -> mapTyRVar α a s
mapTyVars τ (RAllP _ t)   
  = mapTyVars τ t 
mapTyVars τ (RAllS _ t)   
  = mapTyVars τ t 
mapTyVars τ (RCls _ ts)     
  = return ()
mapTyVars τ (RAllE _ _ t)   
  = mapTyVars τ t 
mapTyVars τ (REx _ _ t)
  = mapTyVars τ t 
mapTyVars τ (RExprArg _)
  = return ()
mapTyVars (AppTy τ τ') (RAppTy t t' _) 
  = do  mapTyVars τ t 
        mapTyVars τ' t' 
mapTyVars τ (RHole _)
  = return ()
mapTyVars τ t
  = Ex.throw =<< errmsg <$> get

mapTyRVar α a s@(MTVST αas err)
  = case lookup α αas of
      Just a' | a == a'   -> s
              | otherwise -> Ex.throw err
      Nothing             -> MTVST ((α,a):αas) err

mkVarExpr v 
  | isDataConWorkId v && not (null tvs) && isNothing tfun
  = EApp (dummyLoc $ dataConSymbol (idDataCon v)) []
  | otherwise   
  = EVar $ symbol v
  where t            = varType v
        (tvs, tbase) = splitForAllTys t
        tfun         = splitFunTy_maybe tbase

subsFreeSymbols su  = tx
  where 
    tx              = fmap $ mapSnd $ subst su 

subsFreeSymbolsInv su  = tx
  where 
    tx                 = fmap $ subst su 

subsFreeSymbolsIAliases su  = tx
  where 
    tx                 = fmap (mapFst f . mapSnd f)
    f                  = subst su


subsFreeSymbolsQual su = tx
  where
    tx                 = fmap $ mapBody $ subst su
    mapBody f q        = q { q_body = f (q_body q) }

-- meetDataConSpec :: [(Var, SpecType)] -> [(DataCon, DataConP)] -> [(Var, SpecType)]
meetDataConSpec xts dcs  = M.toList $ L.foldl' upd dcm xts 
  where 
    dcm                  = M.fromList $ dataConSpec dcs
    upd dcm (x, t)       = M.insert x (maybe t (meetPad t) (M.lookup x dcm)) dcm
    strengthen (x,t)     = (x, maybe t (meetPad t) (M.lookup x dcm))


-- dataConSpec :: [(DataCon, DataConP)] -> [(Var, SpecType)]
dataConSpec :: [(DataCon, DataConP)]-> [(Var, (RType Class RTyCon RTyVar RReft))]
dataConSpec dcs = concatMap mkDataConIdsTy [(dc, dataConPSpecType dc t) | (dc, t) <- dcs]

meetPad t1 t2 = -- traceShow ("meetPad: " ++ msg) $
  case (bkUniv t1, bkUniv t2) of
    ((_, π1s, ls1, _), (α2s, [], ls2, t2')) -> meet t1 (mkUnivs α2s π1s (ls1 ++ ls2) t2')
    ((α1s, [], ls1, t1'), (_, π2s, ls2, _)) -> meet (mkUnivs α1s π2s (ls1 ++ ls2) t1') t2
    _                             -> errorstar $ "meetPad: " ++ msg
  where msg = "\nt1 = " ++ showpp t1 ++ "\nt2 = " ++ showpp t2
 
------------------------------------------------------------------
---------- Error-Reader-IO For Bare Transformation ---------------
------------------------------------------------------------------

type BareM a = WriterT [Warn] (ErrorT Error (StateT BareEnv IO)) a

type Warn    = String

type TCEnv   = M.HashMap TyCon RTyCon

data BareEnv = BE { modName  :: !ModName
                  , tcEnv    :: !TCEnv
                  , rtEnv    :: !RTEnv
                  , varEnv   :: ![(Symbol,Var)]
                  , hscEnv   :: HscEnv }

setModule m b = b { modName = m }

inModule m act = do
  old <- gets modName
  modify $ setModule m
  res <- act
  modify $ setModule old
  return res

withVArgs l vs act = do
  old <- gets rtEnv
  mapM (mkExprAlias l . symbol . showpp) vs
  res <- act
  modify $ \be -> be { rtEnv = old }
  return res

addSym x = modify $ \be -> be { varEnv = (varEnv be) `L.union` [x] }

mkExprAlias l v
  = setRTAlias v (Right (RTA v [] [] (RExprArg (EVar $ symbol v)) l))

setRTAlias s a =
  modify $ \b -> b { rtEnv = mapRT (M.insert s a) $ rtEnv b }

setRPAlias s a =
  modify $ \b -> b { rtEnv = mapRP (M.insert s a) $ rtEnv b }

execBare :: BareM a -> BareEnv -> IO (Either Error a)
execBare act benv = 
   do z <- evalStateT (runErrorT (runWriterT act)) benv
      case z of
        Left s        -> return $ Left s
        Right (x, ws) -> do forM_ ws $ putStrLn . ("WARNING: " ++) 
                            return $ Right x


------------------------------------------------------------------
------------------- API: Bare Refinement Types -------------------
------------------------------------------------------------------

makeMeasureSpec :: (ModName, Ms.Spec BareType LocSymbol) -> BareM (Ms.MSpec SpecType DataCon)
makeMeasureSpec (mod,spec) = inModule mod mkSpec
  where
    mkSpec = mkMeasureDCon =<< mkMeasureSort =<< m
    m      = Ms.mkMSpec <$> (mapM expandRTAliasMeasure $ Ms.measures spec)
                        <*> return (Ms.cmeasures spec)
                        <*> (mapM expandRTAliasMeasure $ Ms.imeasures spec)

makeMeasureSpec' = mapFst (mapSnd uRType <$>) . Ms.dataConTypes . first (mapReft ur_reft)

makeClassMeasureSpec (Ms.MSpec {..}) = tx <$> M.elems cmeasMap
  where
    tx (M n s _) = (n, CM n (mapReft ur_reft s) -- [(t,m) | (IM n' t m) <- imeas, n == n']
                   )

makeTargetVars :: ModName -> [Var] -> [String] -> BareM [Var]
makeTargetVars name vs ss = do
  env <- gets hscEnv
  ns <- liftIO $ concatMapM (lookupName env name . dummyLoc . prefix) ss
  return $ filter ((`elem` ns) . varName) vs
 where
  prefix s = qualifySymbol (symbol name) (symbol s)


makeAssertSpec cmod cfg vs lvs (mod,spec)
  | cmod == mod
  = makeLocalSpec cfg cmod vs lvs (Ms.sigs spec ++ Ms.localSigs spec)
  | otherwise
  = inModule mod $ makeSpec cfg vs $ Ms.sigs spec

makeAssumeSpec cmod cfg vs lvs (mod,spec)
  | cmod == mod
  = makeLocalSpec cfg cmod vs lvs $ Ms.asmSigs spec
  | otherwise
  = inModule mod $ makeSpec cfg vs $ Ms.asmSigs spec

makeDefaultMethods :: [Var] -> [(ModName,Var,Located SpecType)]
                   -> [(ModName,Var,Located SpecType)]
makeDefaultMethods defVs sigs
  = [ (m,dmv,t)
    | dmv <- defVs
    , let dm = symbol $ showPpr dmv
    , "$dm" `isPrefixOfSym` (dropModuleNames dm)
    , let mod = takeModuleNames dm
    , let method = qualifySymbol mod $ dropSym 3 (dropModuleNames dm)
    , let mb = L.find ((method `isPrefixOfSym`) . symbol . snd3) sigs
    , isJust mb
    , let Just (m,_,t) = mb
    ]

makeLocalSpec :: Config -> ModName -> [Var] -> [Var] -> [(LocSymbol, BareType)]
                    -> BareM [(ModName, Var, Located SpecType)]
makeLocalSpec cfg mod vs lvs xbs
  = do env     <- get
       vbs1    <- fmap expand3 <$> varSymbols fchoose "Var" lvs (dupSnd <$> xbs1)
       unless (noCheckUnknown cfg) $
         checkDefAsserts env vbs1 xbs1
       vts1    <- map (addFst3 mod) <$> mapM mkVarSpec vbs1
       vts2    <- makeSpec cfg vs xbs2
       return   $ vts1 ++ vts2
  where (xbs1, xbs2)  = L.partition (modElem mod . fst) xbs

        dupSnd (x, y)       = (dropMod x, (x, y))
        expand3 (x, (y, w)) = (x, y, w)

        dropMod  = fmap (dropModuleNames . symbol)

        fchoose ls = maybe ls (:[]) $ L.find (`elem` vs) ls

        modElem n x = (takeModuleNames $ val x) == (symbol n)

makeSpec :: Config -> [Var] -> [(LocSymbol, BareType)]
                -> BareM [(ModName, Var, Located SpecType)]
makeSpec cfg vs xbs
  = do vbs <- map (joinVar vs) <$> lookupIds xbs
       env@(BE { modName = mod}) <- get
       unless (noCheckUnknown cfg) $ checkDefAsserts env vbs xbs
       map (addFst3 mod) <$> mapM mkVarSpec vbs

-- the Vars we lookup in GHC don't always have the same tyvars as the Vars
-- we're given, so return the original var when possible.
-- see tests/pos/ResolvePred.hs for an example
joinVar vs (v,s,t) = case L.find ((== showPpr v) . showPpr) vs of
                       Just v' -> (v',s,t)
                       Nothing -> (v,s,t)

lookupIds = mapM lookup
  where
    lookup (s, t) = (,s,t) <$> lookupGhcVar s

checkDefAsserts :: BareEnv -> [(Var, LocSymbol, BareType)] -> [(LocSymbol, BareType)] -> BareM ()
checkDefAsserts env vbs xbs   = applyNonNull (return ()) grumble  undefSigs
  where
    undefSigs                 = [x | (x, _) <- assertSigs, not (x `S.member` definedSigs)]
    assertSigs                = filter isTarget xbs
    definedSigs               = S.fromList $ snd3 <$> vbs
    grumble                   = mapM_ (warn . berrUnknownVar)
    moduleName                = symbol $ modName env
    isTarget                  = isPrefixOfSym moduleName . stripParensSym . val . fst

warn x = tell [x]


mkVarSpec :: (Var, LocSymbol, BareType) -> BareM (Var, Located SpecType)
mkVarSpec (v, Loc l _, b) = tx <$> mkSpecType l b
  where
    tx = (v,) . Loc l . generalize

plugHoles :: (RReft -> RReft) -> Type -> SpecType -> SpecType
plugHoles f t st = mkArrow αs ps (ls1 ++ ls2) cs' $ go rt' st''
  where
    (αs, _, ls1, rt)  = bkUniv (ofType t :: SpecType)
    (cs, rt')         = bkClass rt

    (_, ps, ls2, st') = bkUniv st
    (_, st'')         = bkClass st'
    cs'               = [(dummySymbol, RCls c t) | (c,t) <- cs]

    go t                (RHole r)          = fmap f t { rt_reft = f r }
    go (RVar _ _)       v@(RVar _ _)       = v
    go (RFun _ i o _)   (RFun x i' o' r)   = RFun x (go i i') (go o o') r
    go (RAllT _ t)      (RAllT a t')       = RAllT a $ go t t'
    go t                (RAllE b a t')     = RAllE b a $ go t t'
    go t                (REx b x t')       = REx b x $ go t t'
    go (RAppTy t1 t2 _) (RAppTy t1' t2' r) = RAppTy (go t1 t1') (go t2 t2') r
    go (RApp _ t _ _)   (RApp c t' p r)    = RApp c (zipWith go t t') p r
    go (RCls _ t)       (RCls c t')        = RCls c $ zipWith go t t'
    go t                st                 = Ex.throw err
     where
       err = errOther $ text msg
       msg = printf "plugHoles: unhandled case!\nt  = %s\nst = %s\n" (showpp t) (showpp st)

showTopLevelVars vs = 
  forM vs $ \v -> 
    when (isExportedId v) $
      donePhase Loud ("Exported: " ++ showPpr v)

----------------------------------------------------------------------

makeTyConEmbeds (mod, spec)
  = inModule mod $ makeTyConEmbeds' $ Ms.embeds spec

makeTyConEmbeds' :: TCEmb (Located Symbol) -> BareM (TCEmb TyCon)
makeTyConEmbeds' z = M.fromList <$> mapM tx (M.toList z)
  where 
    tx (c, y) = (, y) <$> lookupGhcTyCon c

makeIAliases (mod, spec)
  = inModule mod $ makeIAliases' $ Ms.ialiases spec

makeIAliases' :: [(Located BareType, Located BareType)] -> BareM [(Located SpecType, Located SpecType)]
makeIAliases' ts = mapM mkIA ts
  where 
    mkIA (t1, t2)      = liftM2 (,) (mkI t1) (mkI t2)
    mkI (Loc l t)      = (Loc l) . generalize <$> mkSpecType l t

makeInvariants (mod,spec)
  = inModule mod $ makeInvariants' $ Ms.invariants spec

makeInvariants' :: [Located BareType] -> BareM [Located SpecType]
makeInvariants' ts = mapM mkI ts
  where 
    mkI (Loc l t)      = (Loc l) . generalize <$> mkSpecType l t

mkSpecType l t = mkSpecType' l (ty_preds $ toRTypeRep t)  t

mkSpecType' :: SourcePos -> [PVar BSort] -> BareType -> BareM SpecType
mkSpecType' l πs = expandRTAlias l . txParams subvUReft (uPVar <$> πs)

makeSymbols vs xs' xts yts ivs = mkxvs
  where
    xs''  = val <$> xs'
    zs    = concatMap freeSymbols (snd <$> xts) `sortDiff` xs''
    zs'   = concatMap freeSymbols (snd <$> yts) `sortDiff` xs''
    zs''  = concatMap freeSymbols ivs `sortDiff` xs''
    xs    = sortNub $ zs ++ zs' ++ zs''
    mkxvs = do
      svs <- gets varEnv
      return [(x,v') | (x,v) <- svs, x `elem` xs, let (v',_,_) = joinVar vs (v,x,x)]

freeSymbols ty = sortNub $ concat $ efoldReft (\_ _ -> []) (\ _ -> ()) f (\_ -> id) emptySEnv [] (val ty)
  where 
    f γ _ r xs = let Reft (v, _) = toReft r in 
                 [ x | x <- syms r, x /= v, not (x `memberSEnv` γ)] : xs

-----------------------------------------------------------------
------ Querying GHC for Id, Type, Class, Con etc. ---------------
-----------------------------------------------------------------

class Symbolic a => GhcLookup a where
  lookupName :: HscEnv -> ModName -> a -> IO [Name]
  srcSpan    :: a -> SrcSpan

instance GhcLookup (Located Symbol) where
  lookupName e m = symbolLookup e m . val
  srcSpan        = sourcePosSrcSpan . loc

instance GhcLookup Name where
  lookupName _ _ = return . (:[])
  srcSpan        = nameSrcSpan

-- lookupGhcThing :: (GhcLookup a) => String -> (TyThing -> Maybe b) -> a -> BareM b
lookupGhcThing name f x
  = do zs <- lookupGhcThing' name f x
       case zs of
         Just x' -> return x'
         Nothing -> throwError $ ErrGhc (srcSpan x) (text msg)
  where
    msg = "Not in scope: " ++ name ++ " `" ++ symbolString (symbol x) ++ "'"

-- lookupGhcThing' :: (GhcLookup a) => String -> (TyThing -> Maybe b) -> a -> BareM (Maybe b)
lookupGhcThing' _    f x
  = do (BE mod _ _ _ env) <- get
       ns                 <- liftIO $ lookupName env mod x
       mts                <- liftIO $ mapM (fmap (join . fmap f) . hscTcRcLookupName env) ns
       case catMaybes mts of
         []    -> return Nothing
         (t:_) -> return $ Just t

symbolLookup :: HscEnv -> ModName -> Symbol -> IO [Name]
symbolLookup env mod k
  | k `M.member` wiredIn
  = return $ maybeToList $ M.lookup k wiredIn
  | otherwise
  = symbolLookupEnv env mod k

symbolLookupEnv env mod s
  | isSrcImport mod
  = do let modName = getModName mod
       L _ rn <- hscParseIdentifier env $ symbolString s
       res    <- lookupRdrName env modName rn
       -- 'hscParseIdentifier' defaults constructors to 'DataCon's, but we also
       -- need to get the 'TyCon's for declarations like @data Foo = Foo Int@.
       res'   <- lookupRdrName env modName (setRdrNameSpace rn tcName)
       return $ catMaybes [res, res']
  | otherwise
  = do L _ rn         <- hscParseIdentifier env $ symbolString s
       (_, lookupres) <- tcRnLookupRdrName env rn
       case lookupres of
         Just ns -> return ns
         _       -> return []

-- | It's possible that we have already resolved the 'Name' we are looking for,
-- but have had to turn it back into a 'String', e.g. to be used in an 'Expr',
-- as in @{v:Ordering | v = EQ}@. In this case, the fully-qualified 'Name'
-- (@GHC.Types.EQ@) will likely not be in scope, so we store our own mapping of
-- fully-qualified 'Name's to 'Var's and prefer pulling 'Var's from it.
lookupGhcVar :: GhcLookup a => a -> BareM Var
lookupGhcVar x
  = do env <- gets varEnv
       case L.lookup (symbol x) env of
         Nothing -> lookupGhcThing "variable" fv x
         Just v  -> return v
  where
    fv (AnId x)                   = Just x
    fv (AConLike (RealDataCon x)) = Just $ dataConWorkId x
    fv _                          = Nothing

lookupGhcTyCon       ::  GhcLookup a => a -> BareM TyCon
lookupGhcTyCon s     = (lookupGhcThing "type constructor or class" ftc s)
                       `catchError` (tryPropTyCon s)
  where 
    ftc (ATyCon x)   = Just x
    ftc _            = Nothing

tryPropTyCon s e   
  | sx == propConName  = return propTyCon
  | sx == hpropConName = return hpropTyCon
  | otherwise          = throwError e
  where
    sx                 = symbol s
    
lookupGhcClass       = lookupGhcThing "class" ftc
  where 
    ftc (ATyCon x)   = tyConClass_maybe x 
    ftc _            = Nothing

lookupGhcDataCon dc  = case isTupleDC $ val dc of
                         Just n  -> return $ tupleCon BoxedTuple n
                         Nothing -> lookupGhcDataCon' dc 

isTupleDC zs
  | "(," `isPrefixOfSym` zs
  = Just $ lengthSym zs - 1
  | otherwise
  = Nothing

lookupGhcDataCon'    = lookupGhcThing "data constructor" fdc
  where 
    fdc (AConLike (RealDataCon x)) = Just x
    fdc _            = Nothing

wiredIn      :: M.HashMap Symbol Name
wiredIn      = M.fromList $ special ++ wiredIns 
  where
    wiredIns = [ (symbol n, n) | thing <- wiredInThings, let n = getName thing ]
    special  = [ ("GHC.Integer.smallInteger", smallIntegerName)
               , ("GHC.Num.fromInteger"     , fromIntegerName ) ]

class Resolvable a where
  resolve     :: SourcePos -> a -> BareM a

instance Resolvable a => Resolvable [a] where
  resolve = mapM . resolve

instance Resolvable Qualifier where
  resolve _ (Q n ps b l) = Q n <$> mapM (secondM (resolve l)) ps <*> resolve l b <*> return l

instance Resolvable Pred where
  resolve l (PAnd ps)       = PAnd    <$> resolve l ps
  resolve l (POr  ps)       = POr     <$> resolve l ps
  resolve l (PNot p)        = PNot    <$> resolve l p
  resolve l (PImp p q)      = PImp    <$> resolve l p  <*> resolve l q
  resolve l (PIff p q)      = PIff    <$> resolve l p  <*> resolve l q
  resolve l (PBexp b)       = PBexp   <$> resolve l b
  resolve l (PAtom r e1 e2) = PAtom r <$> resolve l e1 <*> resolve l e2
  resolve l (PAll vs p)     = PAll    <$> mapM (secondM (resolve l)) vs <*> resolve l p
  resolve _ p               = return p

instance Resolvable Expr where
  resolve l (EVar s)       = EVar   <$> resolve l s
  resolve l (EApp s es)    = EApp   <$> resolve l s  <*> resolve l es
  resolve l (EBin o e1 e2) = EBin o <$> resolve l e1 <*> resolve l e2
  resolve l (EIte p e1 e2) = EIte   <$> resolve l p  <*> resolve l e1 <*> resolve l e2
  resolve l (ECst x s)     = ECst   <$> resolve l x  <*> resolve l s
  resolve l x              = return x

instance Resolvable LocSymbol where
  resolve _ ls@(Loc l s)
    | s `elem` prims 
    = return ls
    | otherwise 
    = do env <- gets (typeAliases . rtEnv)
         case M.lookup s env of
           Nothing | isCon s -> do v <- lookupGhcVar $ Loc l s
                                   let qs = symbol v
                                   addSym (qs,v)
                                   return $ Loc l qs
           _                 -> return ls

isCon c 
  | Just (c,cs) <- T.uncons $ symbolText c = isUpper c
  | otherwise                              = False

--FIXME: probably need to add a Location to `EVar` so we don't need
--this instance..
instance Resolvable Symbol where
  resolve l x = fmap val $ resolve l $ Loc l x 

instance Resolvable Sort where
  resolve _ FInt         = return FInt
  resolve _ FNum         = return FNum
  resolve _ s@(FObj _)   = return s --FObj . S <$> lookupName env m s
  resolve _ s@(FVar _)   = return s
  resolve l (FFunc i ss) = FFunc i <$> resolve l ss
  resolve _ (FApp tc ss)
    | tcs' `elem` prims  = FApp tc <$> ss'
    | otherwise          = FApp <$> (symbolFTycon.Loc l.symbol <$> lookupGhcTyCon tcs) <*> ss'
      where
        tcs@(Loc l tcs') = fTyconSymbol tc
        ss'              = resolve l ss

instance Resolvable (UReft Reft) where
  resolve l (U r p s) = U <$> resolve l r <*> resolve l p <*> return s

instance Resolvable Reft where
  resolve l (Reft (s, ras)) = Reft . (s,) <$> mapM resolveRefa ras
    where
      resolveRefa (RConc p) = RConc <$> resolve l p
      resolveRefa kv        = return kv

instance Resolvable Predicate where
  resolve l (Pr pvs) = Pr <$> resolve l pvs

instance (Resolvable t) => Resolvable (PVar t) where
  resolve l (PV n t v as) = PV n t v <$> mapM (third3M (resolve l)) as

instance Resolvable () where
  resolve l = return 

--------------------------------------------------------------------
------ Predicate Types for WiredIns --------------------------------
--------------------------------------------------------------------

maxArity :: Arity 
maxArity = 7

wiredTyDataCons :: ([(TyCon, TyConP)] , [(DataCon, Located DataConP)])
wiredTyDataCons = (concat tcs, mapSnd dummyLoc <$> concat dcs)
  where 
    (tcs, dcs)  = unzip l
    l           = [listTyDataCons] ++ map tupleTyDataCons [2..maxArity]

listTyDataCons :: ([(TyCon, TyConP)] , [(DataCon, DataConP)])
listTyDataCons   = ( [(c, TyConP [(RTV tyv)] [p] [] [0] [] (Just fsize))]
                   , [(nilDataCon, DataConP l0 [(RTV tyv)] [p] [] [] [] lt)
                   , (consDataCon, DataConP l0 [(RTV tyv)] [p] [] [] cargs  lt)])
    where
      l0         = dummyPos "LH.Bare.listTyDataCons"
      c          = listTyCon
      [tyv]      = tyConTyVars c
      t          = rVar tyv :: RSort
      fld        = "fldList"
      x          = "xListSelector"
      xs         = "xsListSelector"
      p          = PV "p" (PVProp t) (vv Nothing) [(t, fld, EVar fld)]
      px         = pdVarReft $ PV "p" (PVProp t) (vv Nothing) [(t, fld, EVar x)] 
      lt         = rApp c [xt] [RPropP [] $ pdVarReft p] mempty                 
      xt         = rVar tyv
      xst        = rApp c [RVar (RTV tyv) px] [RPropP [] $ pdVarReft p] mempty
      cargs      = [(xs, xst), (x, xt)]
      fsize      = \x -> EApp (dummyLoc "len") [EVar x]

tupleTyDataCons :: Int -> ([(TyCon, TyConP)] , [(DataCon, DataConP)])
tupleTyDataCons n = ( [(c, TyConP (RTV <$> tyvs) ps [] [0..(n-2)] [] Nothing)]
                    , [(dc, DataConP l0 (RTV <$> tyvs) ps [] []  cargs  lt)])
  where 
    l0            = dummyPos "LH.Bare.tupleTyDataCons"
    c             = tupleTyCon BoxedTuple n
    dc            = tupleCon BoxedTuple n 
    tyvs@(tv:tvs) = tyConTyVars c
    (ta:ts)       = (rVar <$> tyvs) :: [RSort]
    flds          = mks "fld_Tuple"
    fld           = "fld_Tuple"
    x1:xs         = mks ("x_Tuple" ++ show n)
    ps            = mkps pnames (ta:ts) ((fld, EVar fld):(zip flds (EVar <$>flds)))
    ups           = uPVar <$> ps
    pxs           = mkps pnames (ta:ts) ((fld, EVar x1):(zip flds (EVar <$> xs)))
    lt            = rApp c (rVar <$> tyvs) (RPropP [] . pdVarReft <$> ups) mempty
    xts           = zipWith (\v p -> RVar (RTV v) (pdVarReft p)) tvs pxs
    cargs         = reverse $ (x1, rVar tv) : (zip xs xts)
    pnames        = mks_ "p"
    mks  x        = (\i -> symbol (x++ show i)) <$> [1..n]
    mks_ x        = (\i -> symbol (x++ show i)) <$> [2..n]


pdVarReft = (\p -> U mempty p mempty) . pdVar 

mkps ns (t:ts) ((f,x):fxs) = reverse $ mkps_ ns ts fxs [(t, f, x)] []
mkps _  _      _           = error "Bare : mkps"

mkps_ []     _       _          _    ps = ps
mkps_ (n:ns) (t:ts) ((f, x):xs) args ps = mkps_ ns ts xs (a:args) (p:ps)
  where
    p                                   = PV n (PVProp t) (vv Nothing) args
    a                                   = (t, f, x)
mkps_ _     _       _          _    _ = error "Bare : mkps_"

------------------------------------------------------------------------
-- | Transforming Raw Strings using GHC Env ----------------------------
------------------------------------------------------------------------
ofBareType :: (PPrint r, Reftable r) => BRType r -> BareM (RRType r)
------------------------------------------------------------------------
ofBareType (RVar a r) 
  = return $ RVar (symbolRTyVar a) r
ofBareType (RFun x t1 t2 _) 
  = liftM2 (rFun x) (ofBareType t1) (ofBareType t2)
ofBareType t@(RAppTy t1 t2 r) 
  = liftM3 RAppTy (ofBareType t1) (ofBareType t2) (return r)
ofBareType (RAllE x t1 t2)
  = liftM2 (RAllE x) (ofBareType t1) (ofBareType t2)
ofBareType (REx x t1 t2)
  = liftM2 (REx x) (ofBareType t1) (ofBareType t2)
ofBareType (RAllT a t) 
  = liftM  (RAllT (symbolRTyVar a)) (ofBareType t)
ofBareType (RAllP π t) 
  = liftM2 RAllP (ofBPVar π) (ofBareType t)
ofBareType (RAllS s t) 
  = liftM  (RAllS s) (ofBareType t)
ofBareType (RApp tc ts@[_] rs r) 
  | isList tc
  = do tyi <- tcEnv <$> get
       liftM2 (bareTCApp tyi r listTyCon) (mapM ofRef rs) (mapM ofBareType ts)
ofBareType (RApp tc ts rs r) 
  | isTuple tc
  = do tyi <- tcEnv <$> get
       liftM2 (bareTCApp tyi r c) (mapM ofRef rs) (mapM ofBareType ts)
    where c = tupleTyCon BoxedTuple (length ts)
ofBareType (RApp tc ts rs r) 
  = do tyi <- tcEnv <$> get
       liftM3 (bareTCApp tyi r) (lookupGhcTyCon tc) (mapM ofRef rs) (mapM ofBareType ts)
ofBareType (RCls c ts)
  = liftM2 RCls (lookupGhcClass c) (mapM ofBareType ts)
ofBareType (ROth s)
  = return $ ROth s
ofBareType (RHole r)
  = return $ RHole r
ofBareType t
  = errorstar $ "Bare : ofBareType cannot handle " ++ show t

ofRef (RProp ss t)   
  = RProp <$> mapM ofSyms ss <*> ofBareType t
ofRef (RPropP ss r) 
  = (`RPropP` r) <$> mapM ofSyms ss
ofRef (RHProp _ _)
  = errorstar "TODO:EFFECTS:ofRef"


ofSyms (x, t)
  = liftM ((,) x) (ofBareType t)

tyApp (RApp c ts rs r) ts' rs' r' = RApp c (ts ++ ts') (rs ++ rs') (r `meet` r')
tyApp t                []  []  r  = t `strengthen` r

bareTCApp _ r c rs ts | Just (SynonymTyCon rhs) <- synTyConRhs_maybe c
   = tyApp (subsTyVars_meet su $ ofType rhs) (drop nts ts) rs r 
   where tvs = tyConTyVars  c
         su  = zipWith (\a t -> (rTyVar a, toRSort t, t)) tvs ts
         nts = length tvs

-- TODO expandTypeSynonyms here to
bareTCApp _ r c rs ts | isFamilyTyCon c && isTrivial t
  = expandRTypeSynonyms $ t `strengthen` r 
  where t = rApp c ts rs mempty

bareTCApp _ r c rs ts 
  = rApp c ts rs r

expandRTypeSynonyms = ofType . expandTypeSynonyms . toType

symbolRTyVar  = rTyVar . stringTyVar . symbolString
-- stringTyVarTy = TyVarTy . stringTyVar

mkMeasureDCon :: Ms.MSpec t LocSymbol -> BareM (Ms.MSpec t DataCon)
mkMeasureDCon m = (forM (measureCtors m) $ \n -> (val n,) <$> lookupGhcDataCon n)
                  >>= (return . mkMeasureDCon_ m)

mkMeasureDCon_ :: Ms.MSpec t LocSymbol -> [(Symbol, DataCon)] -> Ms.MSpec t DataCon
mkMeasureDCon_ m ndcs = m' {Ms.ctorMap = cm'}
  where 
    m'  = fmap (tx.val) m
    cm' = hashMapMapKeys (tx' . tx) $ Ms.ctorMap m'
    tx  = mlookup (M.fromList ndcs)
    tx' = dataConSymbol

measureCtors ::  Ms.MSpec t LocSymbol -> [LocSymbol]
measureCtors = sortNub . fmap ctor . concat . M.elems . Ms.ctorMap

-- mkMeasureSort :: (PVarable pv, Reftable r) => Ms.MSpec (BRType pv r) bndr-> BareM (Ms.MSpec (RRType pv r) bndr)
mkMeasureSort (Ms.MSpec c mm cm im)
  = Ms.MSpec c <$> forM mm tx <*> forM cm tx <*> forM im tx
    where
      tx m = liftM (\s' -> m {sort = s'}) (ofBareType (sort m))



-----------------------------------------------------------------------
-- | LH Primitive TyCons ----------------------------------------------
-----------------------------------------------------------------------

propTyCon, hpropTyCon :: TyCon 
propTyCon  = symbolTyCon 'w' 24 propConName
hpropTyCon = symbolTyCon 'w' 24 hpropConName  

-----------------------------------------------------------------------
---------------- Bare Predicate: DataCon Definitions ------------------
-----------------------------------------------------------------------

makeConTypes (name,spec) = inModule name $ makeConTypes' $ Ms.dataDecls spec

makeConTypes' :: [DataDecl] -> BareM ([(TyCon, TyConP)], [[(DataCon, Located DataConP)]])
makeConTypes' dcs = unzip <$> mapM ofBDataDecl dcs

ofBDataDecl :: DataDecl -> BareM ((TyCon, TyConP), [(DataCon, Located DataConP)])
ofBDataDecl (D tc as ps ls cts pos sfun)
  = do πs         <- mapM ofBPVar ps
       tc'        <- lookupGhcTyCon tc
       cts'       <- mapM (ofBDataCon lc tc' αs ps ls πs) cts
       let tys     = [t | (_, dcp) <- cts', (_, t) <- tyArgs dcp]
       let initmap = zip (uPVar <$> πs) [0..]
       let varInfo = concatMap (getPsSig initmap True) tys
       let neutral = [0 .. (length πs)] L.\\ (fst <$> varInfo)
       let cov     = neutral ++ [i | (i, b)<- varInfo, b, i >=0]
       let contr   = neutral ++ [i | (i, b)<- varInfo, not b, i >=0]
       return ((tc', TyConP αs πs ls cov contr sfun), (mapSnd (Loc lc) <$> cts'))
    where 
       αs          = RTV . symbolTyVar <$> as
       lc          = loc tc

getPsSig m pos (RAllT _ t) 
  = getPsSig m pos t
getPsSig m pos (RApp _ ts rs r) 
  = addps m pos r ++ concatMap (getPsSig m pos) ts 
    ++ concatMap (getPsSigPs m pos) rs
getPsSig m pos (RVar _ r) 
  = addps m pos r
getPsSig m pos (RAppTy t1 t2 r) 
  = addps m pos r ++ getPsSig m pos t1 ++ getPsSig m pos t2
getPsSig m pos (RFun _ t1 t2 r) 
  = addps m pos r ++ getPsSig m pos t2 ++ getPsSig m (not pos) t1


getPsSigPs m pos (RPropP _ r) = addps m pos r
getPsSigPs m pos (RProp  _ t) = getPsSig m pos t
getPsSigPs _ _   (RHProp _ _) = errorstar "TODO:EFFECTS:getPsSigPs"

addps m pos (U _ ps _) = (flip (,)) pos . f  <$> pvars ps
  where f = fromMaybe (error "Bare.addPs: notfound") . (`L.lookup` m) . uPVar
-- ofBPreds = fmap (fmap stringTyVarTy)
dataDeclTyConP d 
  = do let αs = fmap (RTV . symbolTyVar) (tycTyVars d)  -- as
       πs    <- mapM ofBPVar (tycPVars d)               -- ps
       tc'   <- lookupGhcTyCon (tycName d)              -- tc
       return $ (tc', TyConP αs πs)

-- ofBPreds = fmap (fmap stringTyVarTy)
ofBPVar :: PVar BSort -> BareM (PVar RSort)
ofBPVar = mapM_pvar ofBareType 

mapM_pvar :: (Monad m) => (a -> m b) -> PVar a -> m (PVar b)
mapM_pvar f (PV x t v txys) 
  = do t'    <- forM t f 
       txys' <- mapM (\(t, x, y) -> liftM (, x, y) (f t)) txys 
       return $ PV x t' v txys'

-- TODO:EFFECTS:ofBDataCon
ofBDataCon l tc αs ps ls πs (c, xts)
  = do c'      <- lookupGhcDataCon c
       ts'     <- mapM (mkSpecType' l ps) ts
       let cs   = map ofType (dataConStupidTheta c')
       let t0   = rApp tc rs (RPropP [] . pdVarReft <$> πs) mempty 
       return   $ (c', DataConP l αs πs ls cs (reverse (zip xs ts')) t0)
    where 
       (xs, ts) = unzip xts
       rs       = [rVar α | RTV α <- αs]

-----------------------------------------------------------------------
---------------- Bare Predicate: RefTypes -----------------------------
-----------------------------------------------------------------------

txParams f πs t = mapReft (f (txPvar (predMap πs t))) t

txPvar :: M.HashMap Symbol UsedPVar -> UsedPVar -> UsedPVar 
txPvar m π = π { pargs = args' }
  where args' | not (null (pargs π)) = zipWith (\(_,x ,_) (t,_,y) -> (t, x, y)) (pargs π') (pargs π)
              | otherwise            = pargs π'
        π'    = fromMaybe (errorstar err) $ M.lookup (pname π) m
        err   = "Bare.replaceParams Unbound Predicate Variable: " ++ show π

predMap πs t = {-Ex.assert (M.size xπm == length xπs)-} xπm
  where xπm = M.fromList xπs
        xπs = [(pname π, π) | π <- πs ++ rtypePredBinds t]

rtypePredBinds = map uPVar . ty_preds . toRTypeRep

-- rtypePredBinds t = everything (++) ([] `mkQ` grab) t
--   where grab ((RAllP pv _) :: BRType RPVar RPredicate) = [pv]
--         grab _                                         = []

----------------------------------------------------------------------------------------------
----- Checking GhcSpec -----------------------------------------------------------------------
----------------------------------------------------------------------------------------------

checkGhcSpec :: [(ModName, Ms.BareSpec)]
             -> GhcSpec -> Either [Error] GhcSpec

checkGhcSpec specs sp =  applyNonNull (Right sp) Left errors
  where 
    errors           =  mapMaybe (checkBind "variable"    emb tcEnv env) sigs
                     ++ mapMaybe (checkBind "constructor" emb tcEnv env) (dcons      sp)
                     ++ mapMaybe (checkBind "measure"     emb tcEnv env) (measSpec   sp)
                     ++ mapMaybe (checkExpr "measure"     emb env sigs)  (texprs sp)
                     ++ mapMaybe (checkInv  emb tcEnv env)               (invariants sp)
                     ++ (checkIAl  emb tcEnv env) (ialiases   sp)
                     ++ checkMeasures emb env ms
                     ++ mapMaybe checkMismatch                     sigs
                     ++ checkDuplicate                             (tySigs sp)
                     ++ checkDuplicate                             (asmSigs sp)
                     ++ checkDupIntersect                          (tySigs sp) (asmSigs sp)
                     ++ checkRTAliases "Type Alias" env            tAliases
                     ++ checkRTAliases "Pred Alias" env            pAliases 
                  -- ++ checkDuplicateRTAlias "Predicate Alias"    pAliases  
                  --   ++ checkRTAliasSyms      "Predicate Alias"    (concat [Ms.paliases sp | (_, sp) <- specs])


    tAliases         =  concat [Ms.aliases sp  | (_, sp) <- specs]
    pAliases         =  concat [Ms.paliases sp | (_, sp) <- specs]
    dcons spec       =  [ (v, Loc l dc)        | (v, dc) <- dataConSpec (dconsP spec), let l = getSourcePos v ] 
    emb              =  tcEmbeds sp
    env              =  ghcSpecEnv sp
    tcEnv            =  tyconEnv sp
    ms               =  measures sp
    measSpec sp      =  [(x, uRType <$> t) | (x, t) <- meas sp] 
    sigs             =  tySigs sp ++ asmSigs sp

checkInv :: TCEmb TyCon -> TCEnv -> SEnv SortedReft -> Located SpecType -> Maybe Error
checkInv emb tcEnv env t   = checkTy err emb tcEnv env (val t) 
  where 
    err              = ErrInvt (sourcePosSrcSpan $ loc t) (val t) 

checkIAl :: TCEmb TyCon -> TCEnv -> SEnv SortedReft -> [(Located SpecType, Located SpecType)] -> [Error]
checkIAl emb tcEnv env ials = catMaybes $ concatMap (checkIAlOne emb tcEnv env) ials

checkIAlOne emb tcEnv env (t1, t2) = checkEq : (tcheck <$> [t1, t2])
  where 
    tcheck t = checkTy (err t) emb tcEnv env (val t)
    err    t = ErrIAl (sourcePosSrcSpan $ loc t) (val t) 
    t1'      :: RSort 
    t1'      = toRSort $ val t1
    t2'      :: RSort 
    t2'      = toRSort $ val t2
    checkEq  = if (t1' == t2') then Nothing else Just errmis
    errmis   = ErrIAlMis (sourcePosSrcSpan $ loc t1) (val t1) (val t2) emsg
    emsg     = pprint t1 <+> text "does not match with" <+> pprint t2 


checkRTAliases msg env as = err1s -- ++ err2s
  where 
    err1s                  = checkDuplicateRTAlias msg as
    err2s                  = concatMap (checkRTAliasWF env) as

checkRTAliasWF env a       = {- trace ("checkRTAliasWF: " ++ rtName a) $ -}
                             mkErr <$> filter (not . ok)  aSyms 
  where
    aSyms                  = {- traceShow ("RTAWF: " ++ aName) $ -} syms $ rtBody a
    ok x                   = memberSEnv x env || x `elem` params 
    params                 = symbol <$> rtVArgs a
    mkErr                  = ErrUnbound sp . pprint 
    sp                     = sourcePosSrcSpan (rtPos a)
    aName                  = rtName a


checkBind :: (PPrint v) => String -> TCEmb TyCon -> TCEnv -> SEnv SortedReft -> (v, Located SpecType) -> Maybe Error 
checkBind s emb tcEnv env (v, Loc l t) = checkTy msg emb tcEnv env' t
  where 
    msg                      = ErrTySpec (sourcePosSrcSpan l) (text s <+> pprint v) t 
    env'                     = foldl (\e (x, s) -> insertSEnv x (RR s mempty) e) env wiredSortedSyms

checkExpr :: (Eq v, PPrint v) => String -> TCEmb TyCon -> SEnv SortedReft -> [(v, Located SpecType)] -> (v, [Expr])-> Maybe Error 
checkExpr s emb env vts (v, es) = mkErr <$> go es
  where 
    Loc l t = safeFromJust msg $ L.lookup v vts
    mkErr   = ErrTySpec (sourcePosSrcSpan l) (text s <+> pprint v) t 
    go      = foldl (\err e -> err <|> checkSorted env' e) Nothing  
    env'    = foldl (\e (x, s) -> insertSEnv x s e) env'' wiredSortedSyms
    env''   = mapSEnv sr_sort $ foldl (\e (x,s) -> insertSEnv x s e) env xss
    xss     = mapSnd rSort <$> (uncurry zip $ dropThd3 $ bkArrowDeep t)
    rSort   = rTypeSortedReft emb 
    msg     = "Bare.checkExpr " ++ showpp v ++ " not found\n"
              ++ "\t Try give a haskell type signature to the recursive function"

checkTy :: (Doc -> Error) -> TCEmb TyCon -> TCEnv -> SEnv SortedReft -> SpecType -> Maybe Error
checkTy mkE emb tcEnv env t = mkE <$> checkRType emb env (txRefSort tcEnv emb t)

checkDupIntersect     :: [(Var, Located SpecType)] -> [(Var, Located SpecType)] -> [Error]
checkDupIntersect xts mxts = concatMap mkWrn dups
  where 
    mkWrn (x, t)     = pprWrn x (sourcePosSrcSpan $ loc t)
    dups             = L.intersectBy (\x y -> (fst x == fst y)) mxts xts
    pprWrn v l       = trace ("WARNING: Assume Overwrites Specifications for "++ show v ++ " : " ++ showPpr l) []

checkDuplicate       :: [(Var, Located SpecType)] -> [Error]
checkDuplicate xts   = mkErr <$> dups
  where 
    mkErr (x, ts)    = ErrDupSpecs (getSrcSpan x) (pprint x) (sourcePosSrcSpan . loc <$> ts)
    dups             = [z | z@(x, t1:t2:_) <- M.toList $ group xts ]

checkDuplicateRTAlias :: String -> [RTAlias s a] -> [Error]
checkDuplicateRTAlias s tas = mkErr <$> dups
  where
    mkErr xs@(x:_)          = ErrDupAlias (sourcePosSrcSpan $ rtPos x) 
                                          (text s) 
                                          (pprint $ rtName x) 
                                          (sourcePosSrcSpan . rtPos <$> xs)
    dups                    = [z | z@(_:_:_) <- L.groupBy (\x y -> rtName x == rtName y) tas]



checkMismatch        :: (Var, Located SpecType) -> Maybe Error
checkMismatch (x, t) = if ok then Nothing else Just err
  where 
    ok               = tyCompat x (val t)
    err              = errTypeMismatch x t

tyCompat x t         = lhs == rhs
  where 
    lhs :: RSort     = toRSort t
    rhs :: RSort     = ofType $ varType x
    msg              = printf "tyCompat: l = %s r = %s" (showpp lhs) (showpp rhs)

ghcSpecEnv sp        = fromListSEnv binds
  where 
    emb              = tcEmbeds sp
    binds            =  [(x,        rSort t) | (x, Loc _ t) <- meas sp]
                     ++ [(symbol v, rSort t) | (v, Loc _ t) <- ctors sp]
                     ++ [(x,        vSort v) | (x, v) <- freeSyms sp, isConLikeId v]
    rSort            = rTypeSortedReft emb 
    vSort            = rSort . varRSort 
    varRSort         :: Var -> RSort
    varRSort         = ofType . varType

errTypeMismatch     :: Var -> Located SpecType -> Error
errTypeMismatch x t = ErrMismatch (sourcePosSrcSpan $ loc t) (pprint x) (varType x) (val t)

-------------------------------------------------------------------------------------
-- | This function checks if a type is malformed in a given environment -------------
-------------------------------------------------------------------------------------

-------------------------------------------------------------------------------------
checkRType :: (PPrint r, Reftable r) => TCEmb TyCon -> SEnv SortedReft -> RRType r -> Maybe Doc 
-------------------------------------------------------------------------------------

checkRType emb env t         = efoldReft cb (rTypeSortedReft emb) f insertPEnv env Nothing t 
  where 
    cb c ts                  = classBinds (RCls c ts)
    f env me r err           = err <|> checkReft env emb me r
    insertPEnv p γ           = insertsSEnv γ (mapSnd (rTypeSortedReft emb) <$> pbinds p) 
    pbinds p                 = (pname p, pvarRType p :: RSort) 
                              : [(x, t) | (t, x, _) <- pargs p]


checkReft                    :: (PPrint r, Reftable r) => SEnv SortedReft -> TCEmb TyCon -> Maybe (RRType r) -> r -> Maybe Doc 
checkReft env emb Nothing _  = Nothing -- TODO:RPropP/Ref case, not sure how to check these yet.  
checkReft env emb (Just t) _ = (dr $+$) <$> checkSortedReftFull env' r 
  where 
    r                        = rTypeSortedReft emb t
    dr                       = text "Sort Error in Refinement:" <+> pprint r 
    env'                     = foldl (\e (x, s) -> insertSEnv x (RR s mempty) e) env wiredSortedSyms

-- DONT DELETE the below till we've added pred-checking as well
-- checkReft env emb (Just t) _ = checkSortedReft env xs (rTypeSortedReft emb t) 
--    where xs                  = fromMaybe [] $ params <$> stripRTypeBase t 

-- checkSig env (x, t) 
--   = case filter (not . (`S.member` env)) (freeSymbols t) of
--       [] -> True
--       ys -> errorstar (msg ys) 
--     where 
--       msg ys = printf "Unkown free symbols: %s in specification for %s \n%s\n" (showpp ys) (showpp x) (showpp t)


-------------------------------------------------------------------------------
------------------  Replace Predicate Arguments With Existentials -------------
-------------------------------------------------------------------------------

data ExSt = ExSt { fresh :: Int
                 , emap  :: M.HashMap Symbol (RSort, Expr)
                 , pmap  :: M.HashMap Symbol RPVar 
                 }

-- | Niki: please write more documentation for this, maybe an example? 
-- I can't really tell whats going on... (RJ)

txExpToBind   :: SpecType -> SpecType
txExpToBind t = evalState (expToBindT t) (ExSt 0 M.empty πs)
  where πs = M.fromList [(pname p, p) | p <- ty_preds $ toRTypeRep t ]

expToBindT :: SpecType -> State ExSt SpecType
expToBindT (RVar v r) 
  = expToBindRef r >>= addExists . RVar v
expToBindT (RFun x t1 t2 r) 
  = do t1' <- expToBindT t1
       t2' <- expToBindT t2
       expToBindRef r >>= addExists . RFun x t1' t2'
expToBindT (RAllT a t) 
  = liftM (RAllT a) (expToBindT t)
expToBindT (RAllP p t)
  = liftM (RAllP p) (expToBindT t)
expToBindT (RAllS s t)
  = liftM (RAllS s) (expToBindT t)
expToBindT (RApp c ts rs r) 
  = do ts' <- mapM expToBindT ts
       rs' <- mapM expToBindReft rs
       expToBindRef r >>= addExists . RApp c ts' rs'
expToBindT (RCls c ts)
  = liftM (RCls c) (mapM expToBindT ts)
expToBindT (RAppTy t1 t2 r)
  = do t1' <- expToBindT t1
       t2' <- expToBindT t2
       expToBindRef r >>= addExists . RAppTy t1' t2'
expToBindT t 
  = return t

expToBindReft              :: SpecProp -> State ExSt SpecProp
expToBindReft (RProp s t)  = RProp s  <$> expToBindT t
expToBindReft (RPropP s r) = RPropP s <$> expToBindRef r
expToBindReft (RHProp _ _) = errorstar "TODO:EFFECTS:expToBindReft"

getBinds :: State ExSt (M.HashMap Symbol (RSort, Expr))
getBinds 
  = do bds <- emap <$> get
       modify $ \st -> st{emap = M.empty}
       return bds

addExists t = liftM (M.foldlWithKey' addExist t) getBinds

addExist t x (tx, e) = RAllE x t' t
  where t' = (ofRSort tx) `strengthen` uTop r
        r  = Reft (vv Nothing, [RConc (PAtom Eq (EVar (vv Nothing)) e)])

expToBindRef :: UReft r -> State ExSt (UReft r)
expToBindRef (U r (Pr p) l)
  = mapM expToBind p >>= return . (\p -> U r p l). Pr

expToBind :: UsedPVar -> State ExSt UsedPVar
expToBind p
  = do Just π <- liftM (M.lookup (pname p)) (pmap <$> get)
       let pargs0 = zip (pargs p) (fst3 <$> pargs π)
       pargs' <- mapM expToBindParg pargs0
       return $ p{pargs = pargs'}

expToBindParg :: (((), Symbol, Expr), RSort) -> State ExSt ((), Symbol, Expr)
expToBindParg ((t, s, e), s') = liftM ((,,) t s) (expToBindExpr e s')

expToBindExpr :: Expr ->  RSort -> State ExSt Expr
expToBindExpr e@(EVar s) _ | isLower $ headSym $ symbol s
  = return e
expToBindExpr e t         
  = do s <- freshSymbol
       modify $ \st -> st{emap = M.insert s (t, e) (emap st)}
       return $ EVar s

freshSymbol :: State ExSt Symbol
freshSymbol 
  = do n <- fresh <$> get
       modify $ \s -> s{fresh = n+1}
       return $ symbol $ "ex#" ++ show n

maybeTrue x target exports r
  | not (isHole r) || isInternalName name || inTarget && notExported
  = r
  | otherwise
  = uTop $ Reft ("VV", [])
  where
    inTarget    = moduleName (nameModule name) == getModName target
    name        = getName x
    notExported = not $ getName x `elemNameSet` exports

-------------------------------------------------------------------------------------
-- | Tasteful Error Messages --------------------------------------------------------
-------------------------------------------------------------------------------------

berrUnknownVar       = berrUnknown "Variable"

berrUnknown :: (PPrint a) => String -> Located a -> String 
berrUnknown thing x  = printf "[%s]\nSpecification for unknown %s : %s"  
                         thing (showpp $ loc x) (showpp $ val x)
