{-# LANGUAGE TemplateHaskell, MultiParamTypeClasses, FlexibleInstances, TypeSynonymInstances, PatternGuards, CPP #-}
module Data.Generics.Geniplate(
    genUniverseBi, genUniverseBiT,
    genTransformBi, genTransformBiT,
    genTransformBiM, genTransformBiMT,
    UniverseBi(..), universe, instanceUniverseBi, instanceUniverseBiT,
    TransformBi(..), transform, instanceTransformBi, instanceTransformBiT,
    TransformBiM(..), transformM, instanceTransformBiM, instanceTransformBiMT,
    ) where
import Control.Monad
import Control.Exception(assert)
import Control.Monad.State.Strict
import Data.Maybe
import Language.Haskell.TH
import Language.Haskell.TH.Syntax hiding (lift)
import System.IO

---- Overloaded interface, same as Uniplate.

-- | Class for 'universeBi'.
class UniverseBi s t where
    universeBi :: s -> [t]

-- | Class for 'transformBi'.
class TransformBi s t where
    transformBi :: (s -> s) -> t -> t

-- | Class for 'transformBiM'.
class {-(Monad m) => -} TransformBiM m s t where
    transformBiM :: (s -> m s) -> t -> m t

universe :: (UniverseBi a a) => a -> [a]
universe = universeBi

transform :: (TransformBi a a) => (a -> a) -> a -> a
transform = transformBi

transformM :: (TransformBiM m a a) => (a -> m a) -> a -> m a
transformM = transformBiM

----

-- | Create a 'UniverseBi' instance.
-- The 'TypeQ' argument should be a pair; the /source/ and /target/ types for 'universeBi'.
instanceUniverseBi :: TypeQ         -- ^(source, target) types
                   -> Q [Dec]
instanceUniverseBi = instanceUniverseBiT []

-- | Create a 'UniverseBi' instance with certain types being abstract.
-- The 'TypeQ' argument should be a pair; the /source/ and /target/ types for 'universeBi'.
instanceUniverseBiT :: [TypeQ]      -- ^types not touched by 'universeBi'
                    -> TypeQ        -- ^(source, target) types
                    -> Q [Dec]
instanceUniverseBiT stops ty = instanceUniverseBiT' stops =<< ty

instanceUniverseBiT' :: [TypeQ] -> Type -> Q [Dec]
instanceUniverseBiT' stops (ForallT _ _ t) = instanceUniverseBiT' stops t
instanceUniverseBiT' stops ty | (TupleT _, [from, to]) <- splitTypeApp ty = do
    (ds, f) <- uniBiQ stops from to
    x <- newName "_x"
    let e = LamE [VarP x] $ LetE ds $ AppE (AppE f (VarE x)) (ListE [])
    return $ instDef ''UniverseBi [from, to] 'universeBi e
instanceUniverseBiT' _ t = genError "instanceUniverseBi: the argument should be of the form [t| (S, T) |]"

funDef :: Name -> Exp -> [Dec]
funDef f e = [FunD f [Clause [] (NormalB e) []]]

instDef :: Name -> [Type] -> Name -> Exp -> [Dec]
instDef cls ts met e = [InstanceD [] (foldl AppT (ConT cls) ts) (funDef met e)]

-- | Create a 'TransformBi' instance.
-- The 'TypeQ' argument should be a pair; the /inner/ and /outer/ types for 'transformBi'.
instanceTransformBi :: TypeQ        -- ^(inner, outer) types
                    -> Q [Dec]
instanceTransformBi = instanceTransformBiT []

-- | Create a 'TransformBi' instance with certain types being abstract.
-- The 'TypeQ' argument should be a pair; the /inner/ and /outer/ types for 'transformBi'.
instanceTransformBiT :: [TypeQ]      -- ^types not touched by 'transformBi'
                     -> TypeQ        -- ^(inner, outer) types
                     -> Q [Dec]
instanceTransformBiT stops ty = instanceTransformBiT' stops =<< ty

instanceTransformBiT' :: [TypeQ] -> Type -> Q [Dec]
instanceTransformBiT' stops (ForallT _ _ t) = instanceTransformBiT' stops t
instanceTransformBiT' stops ty | (TupleT _, [ft, st]) <- splitTypeApp ty = do
    f <- newName "_f"
    x <- newName "_x"
    (ds, tr) <- trBiQ raNormal stops f ft st
    let e = LamE [VarP f, VarP x] $ LetE ds $ AppE tr (VarE x)

    return $ instDef ''TransformBi [ft, st] 'transformBi e
instanceTransformBiT' _ t = genError "instanceTransformBiT: the argument should be of the form [t| (S, T) |]"

-- | Create a 'TransformBiM' instance.
instanceTransformBiM :: TypeQ
                     -> TypeQ
                     -> Q [Dec]
instanceTransformBiM = instanceTransformBiMT []

-- | Create a 'TransformBiM' instance with certain types being abstract.
instanceTransformBiMT :: [TypeQ]
                      -> TypeQ
                      -> TypeQ
                      -> Q [Dec]
instanceTransformBiMT stops mndq ty = instanceTransformBiMT' stops mndq =<< ty

instanceTransformBiMT' :: [TypeQ] -> TypeQ -> Type -> Q [Dec]
instanceTransformBiMT' stops mndq (ForallT _ _ t) = instanceTransformBiMT' stops mndq t
instanceTransformBiMT' stops mndq ty | (TupleT _, [ft, st]) <- splitTypeApp ty = do
    mnd <- mndq

    f <- newName "_f"
    x <- newName "_x"
    (ds, tr) <- trBiQ raMonad stops f ft st
    let e = LamE [VarP f, VarP x] $ LetE ds $ AppE tr (VarE x)

    return $ instDef ''TransformBiM [mnd, ft, st] 'transformBiM e
instanceTransformBiMT' _ _ t = genError "instanceTransformBiMT: the argument should be of the form [t| (S, T) |]"


-- | Generate TH code for a function that extracts all subparts of a certain type.
-- The argument to 'genUniverseBi' is a name with the type @S -> [T]@, for some types
-- @S@ and @T@.  The function will extract all subparts of type @T@ from @S@.
genUniverseBi :: Name             -- ^function of type @S -> [T]@
              -> Q Exp
genUniverseBi = genUniverseBiT []

-- | Same as 'genUniverseBi', but does not look inside any types mention in the
-- list of types.
genUniverseBiT :: [TypeQ]         -- ^types not touched by 'universeBi'
               -> Name            -- ^function of type @S -> [T]@
               -> Q Exp
genUniverseBiT stops name = do
    (_tvs, from, tos) <- getNameType name
    let to = unList tos
--    qRunIO $ print (from, to)
    (ds, f) <- uniBiQ stops from to
    x <- newName "_x"
    let e = LamE [VarP x] $ LetE ds $ AppE (AppE f (VarE x)) (ListE [])
--    qRunIO $ do putStrLn $ pprint e; hFlush stdout
    return e

type U = StateT (Map Type Dec, Map Type Bool) Q

instance Quasi U where
    qNewName = lift . qNewName
    qReport b = lift . qReport b
    qRecover = error "Data.Generics.Geniplate: qRecover not implemented"
    qReify = lift . qReify
#if MIN_VERSION_template_haskell(2,7,0)
    qReifyInstances n = lift . qReifyInstances n
#elif MIN_VERSION_template_haskell(2,5,0)
    qClassInstances n = lift . qClassInstances n
#endif
    qLocation = lift qLocation
    qRunIO = lift . qRunIO
#if MIN_VERSION_template_haskell(2,7,0)
    qLookupName ns = lift . qLookupName ns
    qAddDependentFile = lift . qAddDependentFile
#endif

uniBiQ :: [TypeQ] -> Type -> Type -> Q ([Dec], Exp)
uniBiQ stops from ato = do
    ss <- sequence stops
    to <- expandSyn ato
    (f, (m, _)) <- runStateT (uniBi from to) (mEmpty, mFromList $ zip ss (repeat False))
    return (mElems m, f)

uniBi :: Type -> Type -> U Exp
uniBi afrom to = do
    (m, c) <- get
    from <- expandSyn afrom
    case mLookup from m of
        Just (FunD n _) -> return $ VarE n
        _ -> do
            f <- qNewName "_f"
            let mkRec = do
                    put (mInsert from (FunD f [Clause [] (NormalB $ TupE []) []]) m, c)   -- insert something to break recursion, will be replaced below.
                    uniBiCase from to
            cs <- if from == to then do
                      b <- contains' to from
                      if b then do
                          -- Recursive data type, we need the current value and all values inside.
                          g <- qNewName "_g"
                          gcs <- mkRec
                          let dg = FunD g gcs
                          -- Insert with a dummy type, just to get the definition in the map for mElems.
                          modify $ \ (m', c') -> (mInsert (ConT g) dg m', c')
                          unFun [d| f _x _r = _x : $(return (VarE g)) _x _r |]
                       else
                          -- Non-recursive type, just use this value.
                          unFun [d| f _x _r = _x : _r |]
                  else do
                      -- Types differ, look inside.
                      b <- contains to from
                      if b then do
                          -- Occurrences inside, recurse.
                          mkRec
                       else
                          -- No occurrences of to inside from, so add nothing.
                          unFun [d| f _ _r = _r |]
            let d = FunD f cs
            modify $ \ (m', c') -> (mInsert from d m', c')
            return $ VarE f

-- Check if the second type is contained anywhere in the first type.
contains :: Type -> Type -> U Bool
contains to afrom = do
--    qRunIO $ print ("contains", to, from)
    from <- expandSyn afrom
    if from == to then
        return True
     else do
        c <- gets snd
        case mLookup from c of
            Just b  -> return b
            Nothing -> contains' to from

-- Check if the second type is contained somewhere inside the first.
contains' :: Type -> Type -> U Bool
contains' to from = do
--    qRunIO $ print ("contains'", to, from)
    let (con, ts) = splitTypeApp from
    modify $ \ (m, c) -> (m, mInsert from False c)        -- To make the fixpoint of the recursion False.
    b <- case con of
         ConT n    -> containsCon n to ts
         TupleT _  -> fmap or $ mapM (contains to) ts
         ArrowT    -> return False
         ListT     -> if to == from then return True else contains to (head ts)
         VarT _    -> return False
         t         -> genError $ "contains: unexpected type: " ++ pprint from ++ " (" ++ show t ++ ")"
    modify $ \ (m, c) -> (m, mInsert from b c)
    return b

containsCon :: Name -> Type -> [Type] -> U Bool
containsCon con to ts = do
--    qRunIO $ print ("containsCon", con, to, ts)
    (tvs, cons) <- getTyConInfo con
    let conCon (NormalC _ xs) = fmap or $ mapM (field . snd) xs
        conCon (InfixC x1 _ x2) = fmap or $ mapM field [snd x1, snd x2]
        conCon (RecC _ xs) = fmap or $ mapM field [ t | (_,_,t) <- xs ]
        conCon c = genError $ "containsCon: " ++ show c
        s = mkSubst tvs ts
        field t = contains to (subst s t)
    fmap or $ mapM conCon cons

unFunD :: [Dec] -> [Clause]
unFunD [FunD _ cs] = cs
unFunD _ = genError $ "unFunD"

unFun :: Q [Dec] -> U [Clause]
unFun = lift . fmap unFunD

uniBiCase :: Type -> Type -> U [Clause]
uniBiCase from to = do
    let (con, ts) = splitTypeApp from
    case con of
        ConT n    -> uniBiCon n ts to
        TupleT _  -> uniBiTuple ts to
--        ArrowT    -> unFun [d| f _ _r = _r |]           -- Stop at functions
        ListT     -> uniBiList (head ts) to
        t         -> genError $ "uniBiCase: unexpected type: " ++ pprint from ++ " (" ++ show t ++ ")"

uniBiList :: Type -> Type -> U [Clause]
uniBiList t to = do
    uni <- uniBi t to
    rec <- uniBi (AppT ListT t) to
    unFun [d| f [] _r = _r; f (_x:_xs) _r = $(return uni) _x ($(return rec) _xs _r) |]

uniBiTuple :: [Type] -> Type -> U [Clause]
uniBiTuple ts to = fmap (:[]) $ mkArm to [] TupP ts

uniBiCon :: Name -> [Type] -> Type -> U [Clause]
uniBiCon con ts to = do
    (tvs, cons) <- getTyConInfo con
    let genArm (NormalC c xs) = arm (ConP c) xs
        genArm (InfixC x1 c x2) = arm (\ [p1, p2] -> InfixP p1 c p2) [x1, x2]
        genArm (RecC c xs) = arm (ConP c) [ (b,t) | (_,b,t) <- xs ]
        genArm c = genError $ "uniBiCon: " ++ show c
        s = mkSubst tvs ts
        arm c xs = mkArm to s c $ map snd xs

    if null cons then
        -- No constructurs, return nothing
        unFun [d| f _ _r = _r |]
     else
        mapM genArm cons

mkArm :: Type -> Subst -> ([Pat] -> Pat) -> [Type] -> U Clause
mkArm to s c ts = do
    r <- qNewName "_r"
    vs <- mapM (const $ qNewName "_x") ts
    let sub v t = do
            let t' = subst s t
            uni <- uniBi t' to
            return $ AppE (AppE uni (VarE v))
    es <- zipWithM sub vs ts
    let body = foldr ($) (VarE r) es
    return $ Clause [c (map VarP vs), VarP r] (NormalB body) []


type Subst = [(Name, Type)]

mkSubst :: [TyVarBndr] -> [Type] -> Subst
mkSubst vs ts =
   let vs' = map un vs
       un (PlainTV v) = v
       un (KindedTV v _) = v
   in  assert (length vs' == length ts) $ zip vs' ts

subst :: Subst -> Type -> Type
subst s (ForallT v c t) = ForallT v c $ subst s t
subst s t@(VarT n) = fromMaybe t $ lookup n s
subst s (AppT t1 t2) = AppT (subst s t1) (subst s t2)
subst s (SigT t k) = SigT (subst s t) k
subst _ t = t

getTyConInfo :: (Quasi q) => Name -> q ([TyVarBndr], [Con])
getTyConInfo con = do
    info <- qReify con
    case info of
        TyConI (DataD _ _ tvs cs _) -> return (tvs, cs)
        TyConI (NewtypeD _ _ tvs c _) -> return (tvs, [c])
        PrimTyConI{} -> return ([], [])
        i -> genError $ "unexpected TyCon: " ++ show i

getNameType :: (Quasi q) => Name -> q ([TyVarBndr], Type, Type)
getNameType name = do
    info <- qReify name
    let split (ForallT tvs _ t) = (tvs ++ tvs', from, to) where (tvs', from, to) = split t
        split (AppT (AppT ArrowT from) to) = ([], from, to)
        split t = genError $ "Type is not an arrow: " ++ pprint t
    case info of
        VarI _ t _ _ -> return $ split t
        _            -> genError $ "Name is not variable: " ++ pprint name

unList :: Type -> Type
unList (AppT (ConT n) t) | n == ''[] = t
unList (AppT ListT t) = t
unList t = genError $ "universeBi: Type is not a list: " ++ pprint t -- ++ " (" ++ show t ++ ")"

splitTypeApp :: Type -> (Type, [Type])
splitTypeApp (AppT a r) = (c, rs ++ [r]) where (c, rs) = splitTypeApp a
splitTypeApp t = (t, [])

expandSyn :: (Quasi q) => Type -> q Type
expandSyn (ForallT tvs ctx t) = liftM (ForallT tvs ctx) $ expandSyn t
expandSyn t@AppT{} = expandSynApp t []
expandSyn t@ConT{} = expandSynApp t []
expandSyn (SigT t k) = expandSyn t   -- Ignore kind synonyms
expandSyn t = return t

expandSynApp :: (Quasi q) => Type -> [Type] -> q Type
expandSynApp (AppT t1 t2) ts = do t2' <- expandSyn t2; expandSynApp t1 (t2':ts)
expandSynApp (ConT n) ts | nameBase n == "[]" = return $ foldl AppT ListT ts
expandSynApp t@(ConT n) ts = do
    info <- qReify n
    case info of
        TyConI (TySynD _ tvs rhs) ->
            let (ts', ts'') = splitAt (length tvs) ts
                s = mkSubst tvs ts'
                rhs' = subst s rhs
            in  expandSynApp rhs' ts''
        _ -> return $ foldl AppT t ts
expandSynApp t ts = do t' <- expandSyn t; return $ foldl AppT t' ts

genError :: String -> a
genError msg = error $ "Data.Generics.Geniplate: " ++ msg

----------------------------------------------------

-- Exp has type (S -> S) -> T -> T, for some S and T
-- | Generate TH code for a function that transforms all subparts of a certain type.
-- The argument to 'genTransformBi' is a name with the type @(S->S) -> T -> T@, for some types
-- @S@ and @T@.  The function will transform all subparts of type @S@ inside @T@ using the given function.
genTransformBi :: Name       -- ^function of type @(S->S) -> T -> T@
               -> Q Exp
genTransformBi = genTransformBiT []

-- | Same as 'genTransformBi', but does not look inside any types mention in the
-- list of types.
genTransformBiT :: [TypeQ] -> Name -> Q Exp
genTransformBiT = transformBiG raNormal

raNormal :: RetAp
raNormal = (id, AppE, AppE)

genTransformBiM :: Name -> Q Exp
genTransformBiM = genTransformBiMT []

genTransformBiMT :: [TypeQ] -> Name -> Q Exp
genTransformBiMT = transformBiG raMonad

raMonad :: RetAp
raMonad = (eret, eap, emap)
  where eret e = AppE (VarE 'Control.Monad.return) e
        eap f a = AppE (AppE (VarE 'Control.Monad.ap) f) a
        emap f a = AppE (AppE (VarE '(Control.Monad.=<<)) f) a

type RetAp = (Exp -> Exp, Exp -> Exp -> Exp, Exp -> Exp -> Exp)

transformBiG :: RetAp -> [TypeQ] -> Name -> Q Exp
transformBiG ra stops name = do
    (_tvs, fcn, res) <- getNameType name
    f <- newName "_f"
    x <- newName "_x"
    (ds, tr) <-
        case (fcn, res) of
            (AppT (AppT ArrowT s) s',          AppT (AppT ArrowT t) t')           | s == s' && t == t'            -> trBiQ ra stops f s t
            (AppT (AppT ArrowT s) (AppT m s'), AppT (AppT ArrowT t) (AppT m' t')) | s == s' && t == t' && m == m' -> trBiQ ra stops f s t
            _ -> genError $ "transformBi: malformed type: " ++ pprint (AppT (AppT ArrowT fcn) res) ++ ", should have form (S->S) -> (T->T)"
    let e = LamE [VarP f, VarP x] $ LetE ds $ AppE tr (VarE x)
--    qRunIO $ do putStrLn $ pprint e; hFlush stdout
    return e

trBiQ :: RetAp -> [TypeQ] -> Name -> Type -> Type -> Q ([Dec], Exp)
trBiQ ra stops f aft st = do
    ss <- sequence stops
    ft <- expandSyn aft
    (tr, (m, _)) <- runStateT (trBi ra (VarE f) ft st) (mEmpty, mFromList $ zip ss (repeat False))
    return (mElems m, tr)

arrow :: Type -> Type -> Type
arrow t1 t2 = AppT (AppT ArrowT t1) t2

trBi :: RetAp -> Exp -> Type -> Type -> U Exp
trBi ra@(ret, _, rbind) f ft ast = do
    (m, c) <- get
    st <- expandSyn ast
--    qRunIO $ print (ft, st)
    case mLookup st m of
        Just (FunD n _) -> return $ VarE n
        _ -> do
            tr <- qNewName "_tr"
            let mkRec = do
                    put (mInsert st (FunD tr [Clause [] (NormalB $ TupE []) []]) m, c)  -- insert something to break recursion, will be replaced below.
                    trBiCase ra f ft st

            cs <- if ft == st then do
                      b <- contains' ft st
                      if b then do
                          g <- qNewName "_g"
                          gcs <- mkRec
                          let dg = FunD g gcs
                          -- Insert with a dummy type, just to get the definition in the map for mElems.
                          modify $ \ (m', c') -> (mInsert (ConT g) dg m', c')
                          x <- qNewName "_x"
                          return [Clause [VarP x] (NormalB $ rbind f (AppE (VarE g) (VarE x))) []]
                       else do
                          x <- qNewName "_x"
                          return [Clause [VarP x] (NormalB $ AppE f (VarE x)) []]
                  else do
                      b <- contains ft st
--                      qRunIO $ print (b, ft, st)
                      if b then do
                          mkRec
                       else do
                          x <- qNewName "_x"
                          return [Clause [VarP x] (NormalB $ ret $ VarE x) []]
            let d = FunD tr cs
            modify $ \ (m', c') -> (mInsert st d m', c')
            return $ VarE tr

trBiCase :: RetAp -> Exp -> Type -> Type -> U [Clause]
trBiCase ra f ft st = do
    let (con, ts) = splitTypeApp st
    case con of
        ConT n    -> trBiCon ra f n ft st ts
        TupleT _  -> trBiTuple ra f ft st ts
--        ArrowT    -> unFun [d| f _ _r = _r |]           -- Stop at functions
        ListT     -> trBiList ra f ft st (head ts)
        _         -> genError $ "trBiCase: unexpected type: " ++ pprint st ++ " (" ++ show st ++ ")"

trBiList :: RetAp -> Exp -> Type -> Type -> Type -> U [Clause]
trBiList ra f ft st et = do
    nil <- trMkArm ra f ft st [] (const $ ListP []) (ListE []) []
    cons <- trMkArm ra f ft st [] (ConP '(:)) (ConE '(:)) [et, st]
    return [nil, cons]

trBiTuple :: RetAp -> Exp -> Type -> Type -> [Type] -> U [Clause]
trBiTuple ra f ft st ts = do
    vs <- mapM (const $ qNewName "_t") ts
    let tupE = LamE (map VarP vs) $ TupE (map VarE vs)
    c <- trMkArm ra f ft st [] TupP tupE ts
    return [c]

trBiCon :: RetAp -> Exp -> Name -> Type -> Type -> [Type] -> U [Clause]
trBiCon ra f con ft st ts = do
    (tvs, cons) <- getTyConInfo con
    let genArm (NormalC c xs) = arm (ConP c) (ConE c) xs
        genArm (InfixC x1 c x2) = arm (\ [p1, p2] -> InfixP p1 c p2) (ConE c) [x1, x2]
        genArm (RecC c xs) = arm (ConP c) (ConE c) [ (b,t) | (_,b,t) <- xs ]
        genArm c = genError $ "trBiCon: " ++ show c
        s = mkSubst tvs ts
        arm c ec xs = trMkArm ra f ft st s c ec $ map snd xs
    mapM genArm cons

trMkArm :: RetAp -> Exp -> Type -> Type -> Subst -> ([Pat] -> Pat) -> Exp -> [Type] -> U Clause
trMkArm ra@(ret, apl, _) f ft st s c ec ts = do
    vs <- mapM (const $ qNewName "_x") ts
    let sub v t = do
            let t' = subst s t
            tr <- trBi ra f ft t'
            return $ AppE tr (VarE v)
        conTy = foldr arrow st (map (subst s) ts)
    es <- zipWithM sub vs ts
    let body = foldl apl (ret ec) es
    return $ Clause [c (map VarP vs)] (NormalB body) []


----------------------------------------------------

-- Can't use Data.Map since TH stuff is not in Ord

newtype Map a b = Map [(a, b)]

mEmpty :: Map a b
mEmpty = Map []

mLookup :: (Eq a) => a -> Map a b -> Maybe b
mLookup a (Map xys) = lookup a xys

mInsert :: (Eq a) => a -> b -> Map a b -> Map a b
mInsert a b (Map xys) = Map $ (a, b) : filter ((/= a) . fst) xys

mElems :: Map a b -> [b]
mElems (Map xys) = map snd xys

mFromList :: [(a, b)] -> Map a b
mFromList xys = Map xys
