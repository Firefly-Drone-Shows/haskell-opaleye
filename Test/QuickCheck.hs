{-# LANGUAGE Arrows #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeSynonymInstances #-}

module QuickCheck where

import           Prelude hiding (compare, (.), id)
import qualified Opaleye as O
import qualified Opaleye.MaybeFields as OMF
import qualified Opaleye.Internal.Lateral as OL
import qualified Opaleye.Internal.MaybeFields as OM
import qualified Opaleye.Internal.Values as OV
import qualified Opaleye.Internal.Distinct as OD
import qualified Opaleye.ToFields as O
import           Wrapped (constructor, asSumProfunctor,
                          constructorDecidable, asDecidable)
import qualified Database.PostgreSQL.Simple as PGS
import qualified Test.QuickCheck as TQ
import           Test.QuickCheck ((===))
import           Control.Applicative (Applicative, pure, (<$>), (<*>), liftA2)
import           Control.Category (Category, (.), id)
import           Control.Monad (when, (<=<))
import qualified Data.Profunctor.Product.Default as D
import qualified Data.Either
import           Data.List (sort)
import qualified Data.List as List
import qualified Data.MultiSet as MultiSet
import qualified Data.Profunctor as P
import qualified Data.Profunctor.Product as PP
import qualified Data.Functor.Contravariant.Divisible as Divisible
import qualified Data.Monoid as Monoid
import qualified Data.Ord as Ord hiding (compare)
import qualified Data.Set as Set
import qualified Data.Maybe as Maybe
import qualified Control.Arrow as Arrow
import           Control.Arrow ((<<<), (>>>), (&&&), (***))
import qualified Type.Reflection as R

twoIntTable :: String
            -> O.Table (O.Field O.SqlInt4, O.Field O.SqlInt4)
                       (O.Field O.SqlInt4, O.Field O.SqlInt4)
twoIntTable n = O.Table n (PP.p2 (O.required "column1", O.required "column2"))

table1 :: O.Table (O.Field O.SqlInt4, O.Field O.SqlInt4)
                  (O.Field O.SqlInt4, O.Field O.SqlInt4)
table1 = twoIntTable "table1"

newtype SelectArrDenotation a b =
  SelectArrDenotation { unSelectArrDenotation :: PGS.Connection -> [a] -> IO [b] }

type SelectDenotation = SelectArrDenotation ()

unSelectDenotation :: SelectDenotation b -> PGS.Connection -> IO [b]
unSelectDenotation sa conn = unSelectArrDenotation sa conn [()]

onList :: ([a] -> [b]) -> SelectDenotation a -> SelectDenotation b
onList f = SelectArrDenotation . (fmap . fmap . fmap) f . unSelectArrDenotation

data Choice i b s = CInt i | CBool b | CString s deriving (Show, Eq, Ord)

chooseChoice :: Divisible.Decidable f
             => (a -> Choice i b s) -> f i -> f b -> f s -> f a
chooseChoice choose fi fb fs = asDecidable $ proc a -> case choose a of
  CInt i    -> constructorDecidable fi -< i
  CBool b   -> constructorDecidable fb -< b
  CString s -> constructorDecidable fs -< s

newtype Choices m i b s =
  Choices { unChoices :: [Either (Choice i b s) (m (Choices m i b s))] }

deriving instance Show Haskells
deriving instance Eq Haskells
deriving instance Ord Haskells

type SimpleField = Choice (O.Field O.SqlInt4)
                          (O.Field O.SqlBool)
                          (O.Field O.SqlText)
type Fields = Choices O.MaybeFields (O.Field O.SqlInt4)
                                    (O.Field O.SqlBool)
                                    (O.Field O.SqlText)
type Haskells = Choices Maybe Int Bool String

emptyChoices :: Choices m i b s
emptyChoices = Choices []

appendChoices :: Choices m i b s -> Choices m i b s -> Choices m i b s
appendChoices c1 c2 = Choices (unChoices c1 ++ unChoices c2)

ppChoices :: (PP.SumProfunctor p, PP.ProductProfunctor p)
          => p (Choice i b s) (Choice i' b' s')
          -> (p (Choices m i b s) (Choices m' i' b' s')
             -> p (m (Choices m i b s)) (m' (Choices m' i' b' s')))
          -> p (Choices m i b s) (Choices m' i' b' s')
ppChoices p f = ps
  where ps = P.dimap unChoices Choices (PP.list (p PP.+++! f ps))

fieldsOfHaskells :: Haskells -> Fields
fieldsOfHaskells = O.toFieldsExplicit toFieldsFields

fieldsList :: Functor m => (a, b, m s) -> Choices m a b s
fieldsList (x, y, ms) =
  Choices [ Left (CInt x),
            Left (CBool y),
            Right (fmap (Choices . pure . Left . CString) ms)
          ]

type FieldsTuple = (O.Field O.SqlInt4,
                    O.Field O.SqlBool,
                    O.MaybeFields (O.Field O.SqlText))
type HaskellsTuple = (Int, Bool, Maybe String)

listFieldsG :: Functor m
            => Choices m i b s -> i -> b -> s -> m s -> (i, b, m s)
listFieldsG f i b s ms = (fst (firstIntOr i f),
                          fst (firstBoolOrTrue b f),
                          ms')
  where ms' = maybe ms (fmap (fst . firstStringOr s)) (firstMaybe f)

listFields :: Fields -> FieldsTuple
listFields f =
  listFieldsG f 1 (O.sqlBool True) (O.sqlString "xyz") O.nothingFields

listHaskells :: Haskells -> HaskellsTuple
listHaskells f = listFieldsG f 1 True "xyz" Nothing

newtype ArbitrarySelect   = ArbitrarySelect (O.Select Fields)
newtype ArbitrarySelectMaybe =
  ArbitrarySelectMaybe (O.Select (O.MaybeFields Fields))
newtype ArbitrarySelectArr = ArbitrarySelectArr (O.SelectArr Fields Fields)
newtype ArbitraryHaskells = ArbitraryHaskells { unArbitraryHaskells :: Haskells }
                        deriving Show
newtype ArbitraryHaskellsList =
  ArbitraryHaskellsList { unArbitraryHaskellsList :: [HaskellsTuple] }
                             deriving Show
newtype ArbitraryPositiveInt = ArbitraryPositiveInt Int
                            deriving Show
newtype ArbitraryOrder = ArbitraryOrder { unArbitraryOrder :: [(Order, Int)] }
                      deriving Show
newtype ArbitraryFunction =
  ArbitraryFunction { unArbitraryFunction :: forall m i b s.
                      Functor m => Choices m i b s -> Choices m i b s }

data Order = Asc | Desc deriving Show

unpackFields :: O.Unpackspec Fields Fields
unpackFields = defChoicesPP O.unpackspecMaybeFields

distinctNullsFields :: OM.WithNulls OD.Distinctspec Fields Fields
distinctNullsFields =
  ppChoices defChoicePP (OM.mapMaybeFieldsWithNulls D.def)

distinctFields :: OD.Distinctspec Fields Fields
distinctFields = P.dimap unChoices Choices (PP.list
    (defChoicePP PP.+++! OM.unWithNulls D.def distinctNullsFields))

fromFieldsFields :: O.FromFields Fields Haskells
fromFieldsFields = defChoicesPP O.fromFieldsMaybeFields

toFieldsFields :: O.ToFields Haskells Fields
toFieldsFields =
  defChoicesPP (O.toFieldsMaybeFields (fmap Choices OV.nullspecList))

-- We don't have the ability to aggregate MaybeFields, at least, not
-- yet.  Therefore we just replace them with Nothing.
aggregateFields :: O.Aggregator Fields Fields
aggregateFields =
  -- The requirement to cast to int4 is silly, but we still have a bug
  --
  --     https://github.com/tomjaguarpaw/haskell-opaleye/issues/117
  ppChoices (choicePP (P.rmap (O.unsafeCast "int4") O.sum)
                      O.boolAnd
                      (O.stringAgg (O.sqlString ", ")))
            (const (PP.purePP (O.nothingFieldsExplicit (pure emptyChoices))))

aggregateLaterally :: O.Aggregator b b'
                   -> O.SelectArr i (Fields, b)
                   -> O.SelectArr i (Fields, b')
aggregateLaterally agg q = proc i -> do
  (a, b) <- q -< i

  b' <- OL.lateral
    (\(a, b) ->
        let aLateralInt :: O.Field O.SqlInt4
            aLateralInt = fst (firstIntOr 0 a)
        in O.aggregateOrdered (O.asc (const aLateralInt)) agg (pure b))
            -< (a, b)
  Arrow.returnA -< (a, b')

-- This is taking liberties.  Firstly it errors out when two fields
-- are of different types.  It should probably return a Maybe or an
-- Either.  Secondly, it doesn't detect when lists are the same
-- length and it probably should.
--
-- We don't have the ability to aggregate MaybeFields, at least, not
-- yet.  Therefore we just replace them with Nothing.
aggregateDenotation :: [Haskells] -> [Haskells]
aggregateDenotation cs = if null cs
                         then []
                         else (pure
                              . List.foldl1' combine
                              . map emptyOutChoices
                              ) cs
  where combine h1 h2 = Choices (zipWith (curry (\case
          (Left l1, Left l2) -> Left $ case (l1, l2) of
            (CInt  i1, CInt i2)  -> CInt (i1 + i2)
            (CBool b1, CBool b2) -> CBool (b1 && b2)
            (CString s1, CString s2) -> CString (s1 ++ ", " ++ s2)
            _ -> error "Impossible"
          (Right _, Right _) -> Right Nothing
          _ -> error "Impossible")) (unChoices h1) (unChoices h2))

        emptyOutChoices c = Choices $ flip map (unChoices c) $ \case
            Left l  -> Left l
            Right _ -> Right Nothing

optionalDenotation :: [Haskells] -> [Maybe Haskells]
optionalDenotation = \case
  [] -> [Nothing]
  xs -> map Just xs

traverseDenotation :: SelectArrDenotation a Haskells
                   -> SelectDenotation (Maybe a)
                   -> SelectDenotation (Maybe Haskells)
traverseDenotation (SelectArrDenotation f) (SelectArrDenotation q) =
  (SelectArrDenotation (\conn l -> do
                           qr <- q conn l
                           let nothings :: [()]
                               (nothings, justs) =
                                 Data.Either.partitionEithers
                                   (map (\case
                                            Nothing -> Left ()
                                            Just j -> Right j)
                                        qr)

                           justs' <- f conn justs
                           let _ = justs' :: [Haskells]

                           return ((Just <$> justs')
                                   ++ (Nothing <$ nothings))))

data FieldsType f h where
  FInt    :: FieldsType (O.Field O.SqlInt4) Int
  FString :: FieldsType (O.Field O.SqlText) String
  FBool   :: FieldsType (O.Field O.SqlBool) Bool

  FPair  :: (R.Typeable f1, R.Typeable f2,
             R.Typeable h1, R.Typeable h2)
         => FieldsType f1 h1 -> FieldsType f2 h2 -> FieldsType (f1, f2) (h1, h2)

  FMaybe :: (R.Typeable f1, R.Typeable h1)
         => FieldsType f1 h1 -> FieldsType (O.MaybeFields f1) (Maybe h1)

fieldsTypePP :: PP.ProductProfunctor p
             => p (O.Field O.SqlInt4) (O.Field O.SqlInt4)
             -> p (O.Field O.SqlText) (O.Field O.SqlText)
             -> p (O.Field O.SqlBool) (O.Field O.SqlBool)
             -> (forall a b. p a b -> p (O.MaybeFields a) (O.MaybeFields b))
             -> FieldsType f h
             -> p f f
fieldsTypePP i s b m = \case
    FInt    -> i
    FBool   -> b
    FString -> s

    FPair p1 p2 -> PP.p2 (fieldsTypePP i s b m p1,
                          fieldsTypePP i s b m p2)

    FMaybe m1 -> m (fieldsTypePP i s b m m1)

fieldsTypePPH :: PP.ProductProfunctor p
              => p (O.Field O.SqlInt4) Int
              -> p (O.Field O.SqlText) String
              -> p (O.Field O.SqlBool) Bool
              -> (forall a b. p a b -> p (O.MaybeFields a) (Maybe b))
              -> FieldsType f h
              -> p f h
fieldsTypePPH i s b m = \case
    FInt    -> i
    FBool   -> b
    FString -> s

    FPair p1 p2 -> PP.p2 (fieldsTypePPH i s b m p1,
                          fieldsTypePPH i s b m p2)

    FMaybe m1 -> m (fieldsTypePPH i s b m m1)

fieldsTypePPF :: PP.ProductProfunctor p
              => p Int (O.Field O.SqlInt4)
              -> p String (O.Field O.SqlText)
              -> p Bool (O.Field O.SqlBool)
              -> (forall a b. p a b -> p (Maybe a) (O.MaybeFields b))
              -> FieldsType f h
              -> p h f
fieldsTypePPF i s b m = \case
    FInt    -> i
    FBool   -> b
    FString -> s

    FPair p1 p2 -> PP.p2 (fieldsTypePPF i s b m p1,
                          fieldsTypePPF i s b m p2)

    FMaybe m1 -> m (fieldsTypePPF i s b m m1)

data SomeType2 f where
  SomeType2 :: (R.Typeable a, R.Typeable b)
            => R.TypeRep a -> R.TypeRep b -> f a b -> SomeType2 f

type SomeFields = SomeType2 FieldsType

someFields :: (R.Typeable a, R.Typeable b) => f a b -> SomeType2 f
someFields = SomeType2 R.typeRep R.typeRep

genSomeFields :: TQ.Gen SomeFields
genSomeFields = do
  c <- TQ.choose (1, 10 :: Int)

  if c <= 3
  then TQ.oneof [ pure (someFields FInt)
                , pure (someFields FString)
                , pure (someFields FBool) ]
  else if c <= 8
  then genSomeFields >>= \case SomeType2 _ _ a -> pure (someFields (FMaybe a))
  else if c <= 10
  then do
    genSomeFields >>= \case { SomeType2 _ _ u1 ->
    genSomeFields >>= \case { SomeType2 _ _ u2 ->
    pure (someFields (FPair u1 u2)) }}
  else error "Impossible"

eqT :: (R.Typeable a, R.Typeable b) => Maybe (a R.:~~: b)
eqT = R.eqTypeRep R.typeRep R.typeRep

eqFieldsTypeF :: (R.Typeable f1, R.Typeable f2,
                  R.Typeable h1, R.Typeable h2)
              => FieldsType f1 h1 -> FieldsType f2 h2
              -> Maybe ((f1, h1) R.:~~: (f2, h2))
eqFieldsTypeF _ _ = eqT

fmapMaybe :: (a -> b) -> Maybe a -> Maybe b
fmapMaybe = fmap

isMaybe :: FieldsType mf mh
        -> (forall f h.
            (mf ~ O.MaybeFields f, mh ~ Maybe h, R.Typeable f, R.Typeable h)
            => FieldsType f h
            -> r)
        -> Maybe r
isMaybe ft k = case ft of
  FMaybe m -> Just (k m)
  _        -> Nothing

genHaskells :: R.Typeable f
            => FieldsType f h
            -> TQ.Gen h
genHaskells = \case
  FInt    -> TQ.arbitrary
  FBool   -> TQ.arbitrary
  FString -> arbitraryPGString
  FPair p1 p2 -> (,) <$> genHaskells p1 <*> genHaskells p2
  FMaybe m -> TQ.oneof [ Just <$> genHaskells m
                       , pure Nothing ]

-- Structurally recursive on the types, so it will find a solution
-- relatively quickly
easyGenFunction :: (R.Typeable f1,
                    R.Typeable f2,
                    R.Typeable h1,
                    R.Typeable h2)
                => FieldsType f1 h1
                -> FieldsType f2 h2
                -> TQ.Gen (f1 -> f2, h1 -> h2)
easyGenFunction f1 f2 = case f2 of
  FInt -> case f1 of
    FInt    -> pure (id, id)
    -- Could choose these randomly and/or based on the Bool/String in
    -- question, but for now we will just use constants.
    FBool   -> pure (const 123, const 123)
    FString -> pure (const 456, const 456)
    FMaybe m -> do
      (f, h) <- easyGenFunction m FInt
      pure (O.maybeFields 789 f, maybe 789 h)

    FPair p1 p2 -> do
      TQ.oneof [ do
                   (f, h) <- easyGenFunction p1 FInt
                   pure (f . fst, h . fst)
               , do
                   (f, h) <- easyGenFunction p2 FInt
                   pure (f . snd, h . snd)
               ]

  FBool -> case f1 of
    FBool -> pure (id, id)

    FInt    -> pure (const (O.sqlBool True), const True)
    FString -> pure (const (O.sqlBool False), const False)
    FMaybe m -> do
      (f, h) <- easyGenFunction m FBool
      pure (O.maybeFields (O.sqlBool True) f, maybe True h)

    FPair p1 p2 -> do
      TQ.oneof [ do
                   (f, h) <- easyGenFunction p1 FBool
                   pure (f . fst, h . fst)
               , do
                   (f, h) <- easyGenFunction p2 FBool
                   pure (f . snd, h . snd)
               ]

  FString -> case f1 of
    FString -> pure (id, id)

    FInt    -> pure (const (O.sqlString "one"), const "one")
    FBool   -> pure (const (O.sqlString "two"), const "two")
    FMaybe m -> do
      (f, h) <- easyGenFunction m FString
      pure (O.maybeFields (O.sqlString "three") f, maybe "three" h)

    FPair p1 p2 -> do
      TQ.oneof [ do
                   (f, h) <- easyGenFunction p1 FString
                   pure (f . fst, h . fst)
               , do
                   (f, h) <- easyGenFunction p2 FString
                   pure (f . snd, h . snd)
               ]

  -- Would also like to do nothingFields but that requires having the
  -- right adaptor in scope.  When we put it in the FieldsType we can
  -- do it.
  FMaybe m -> TQ.oneof [ do
                           (f, h) <- easyGenFunction f1 m
                           pure (pure . f, Just . h)
                       ]

  FPair p1 p2 -> do
    (fp1, hp1) <- easyGenFunction f1 p1
    (fp2, hp2) <- easyGenFunction f1 p2
    pure (fp1 &&& fp2, hp1 &&& hp2)

genFunction :: (R.Typeable f1,
                R.Typeable f2,
                R.Typeable h1,
                R.Typeable h2)
            => FieldsType f1 h1
            -> FieldsType f2 h2
            -> TQ.Gen (f1 -> f2, h1 -> h2)
genFunction f1 f2 = TQ.oneof choices
  where choices = concat [ [ easyGenFunction f1 f2 ]
                         , identity_
                         , mapMaybe
                         , split
                         , parallel
                         , compose_
                         ]
        identity_ = case eqFieldsTypeF f1 f2 of
          Nothing      -> []
          Just R.HRefl -> [ pure (id, id) ]

        mapMaybe = Maybe.fromMaybe [] $ isMaybe f1 (\m1 ->
                   Maybe.fromMaybe [] $ isMaybe f2 (\m2 ->
                     [ do
                         (f, f') <- genFunction m1 m2
                         return (fmap f, fmap f')
                     ]))

        split = case f2 of { FPair p1 p2 ->
                     [ do
                         (g1, g1') <- genFunction f1 p1
                         (g2, g2') <- genFunction f1 p2
                         return (g1 &&& g2, g1' &&& g2')
                     ];
                     _ -> [] }

        parallel = case f1 of { FPair p1 p2 ->
                   case f2 of { FPair q1 q2 ->
                     [ do
                         (g1, g1') <- genFunction p1 q1
                         (g2, g2') <- genFunction p2 q2
                         return (g1 *** g2, g1' *** g2')
                     ];
                     _ -> [] };
                     _ -> [] }

        compose_ = [ do
                       genSomeFields >>= \case { SomeType2 _ _ f -> do
                         (g1, g1') <- genFunction f1 f
                         (g2, g2') <- genFunction f f2
                         return (g2 . g1, g2' . g1') }
                   ]


instance Show ArbitrarySelect where
  show (ArbitrarySelect q) = maybe "Empty query" id
                              (O.showSqlExplicit unpackFields q)

instance Show ArbitrarySelectMaybe where
  show (ArbitrarySelectMaybe q) =
    maybe "Empty query" id
          (O.showSqlExplicit (O.unpackspecMaybeFields unpackFields) q)

instance Show ArbitrarySelectArr where
  -- We could plug in dummy data here, or maybe just an empty list
  show _ = "ArbitrarySelectArr"

instance Show ArbitraryFunction where
  show = const "A function"

instance TQ.Arbitrary ArbitrarySelect where
  arbitrary = do
    -- The range of choose is inclusive
    c <- TQ.choose (1, 10 :: Int)

    if c <= 3
    then TQ.oneof arbitrarySelectRecurse0
    else if c <= 8
    then TQ.oneof arbitrarySelectRecurse1
    else if c <= 10
    then TQ.oneof arbitrarySelectRecurse2
    else error "Impossible"

instance TQ.Arbitrary ArbitrarySelectArr where
  arbitrary = do
    -- The range of choose is inclusive
    c <- TQ.choose (1, 10 :: Int)

    if c <= 3
    then TQ.oneof arbitrarySelectArrRecurse0
    else if c <= 8
    then TQ.oneof arbitrarySelectArrRecurse1
    else if c <= 10
    then TQ.oneof arbitrarySelectArrRecurse2
    else error "Impossible"

-- It would be better if ArbitrarySelect recursively called this, but
-- it will do for now.
instance TQ.Arbitrary ArbitrarySelectMaybe where
  arbitrary = do
    TQ.oneof $
      (fmap . fmap) ArbitrarySelectMaybe $
      map (\fg -> do { ArbitrarySelect q <- TQ.arbitrary
                     ; f <- fg
                     ; return (f q)
                     })
      genSelectArrMaybeMapper
      ++
      [ do
          ArbitrarySelect q <- TQ.arbitrary
          return (fmap fieldsToMaybeFields q)
      ]

-- [Note] Testing strategy
--
-- We have to be very careful otherwise we will generate
-- infinite-sized expressions.  On the other hand we probably generate
-- far too small small expressions.  We should probably improve that
-- but explicitly passing a size parameter to the sub-generators.
--
-- The idea here is that only arbitrary... generators can do
-- recursion, i.e. call arbitrary in a way that could lead to other
-- calls of arbitrary.  The gen... functions don't call arbitrary
-- again, but can return functions to which arbitrary argument can be
-- applied by arbitrary... generators.

arbitrarySelectRecurse0 :: [TQ.Gen ArbitrarySelect]
arbitrarySelectRecurse0 =
  (fmap . fmap) ArbitrarySelect $
  genSelect

arbitrarySelectRecurse1 :: [TQ.Gen ArbitrarySelect]
arbitrarySelectRecurse1 =
  (fmap . fmap) ArbitrarySelect $
  -- I'm not sure this is neccessary anymore.  It should be covered by
  -- other generation pathways.
  [ do
      ArbitrarySelectArr q <- TQ.arbitrary
      return (q <<< pure emptyChoices)
  ]
  ++
  map (\fg -> do { ArbitrarySelect q <- TQ.arbitrary
                 ; f <- fg
                 ; return (f q) })
      genSelectMapper

arbitrarySelectRecurse2 :: [TQ.Gen ArbitrarySelect]
arbitrarySelectRecurse2 =
    (fmap . fmap) ArbitrarySelect $
    map (\fg -> do { ArbitrarySelect q1 <- TQ.arbitrary
                   ; ArbitrarySelect q2 <- TQ.arbitrary
                   ; f <- fg
                   ; pure (f q1 q2)
                   })
    genSelectArrPoly
    ++
    map (\fg -> do { ArbitrarySelectArr q1 <- TQ.arbitrary
                   ; ArbitrarySelect q2 <- TQ.arbitrary
                   ; f <- fg
                   ; pure (f q1 q2)
                   })
    genSelectArrMapper2
    ++
    map (\fg -> do { ArbitrarySelect q1 <- TQ.arbitrary
                   ; ArbitrarySelect q2 <- TQ.arbitrary
                   ; f <- fg
                   ; pure (f q1 q2)
                   })
    genSelectMapper2

arbitrarySelectArrRecurse0 :: [TQ.Gen ArbitrarySelectArr]
arbitrarySelectArrRecurse0 =
  (fmap . fmap) ArbitrarySelectArr $
     map (fmap ignoreArguments) genSelect
  ++ genFieldsFunction
  where ignoreArguments = P.lmap (const ())

arbitrarySelectArrRecurse1 :: [TQ.Gen ArbitrarySelectArr]
arbitrarySelectArrRecurse1 =
    (fmap . fmap) ArbitrarySelectArr $
    map (\fg -> do { ArbitrarySelectArr q <- TQ.arbitrary
                   ; f <- fg
                   ; pure (OL.laterally f q) })
        genSelectMapper
    ++
    map (\fg -> do { ArbitrarySelectArr q <- TQ.arbitrary
                   ; f <- fg
                   ; pure (f q) })
        genSelectArrMapper
    ++
    map (\fg -> do { ArbitrarySelectArr q <- TQ.arbitrary
                   ; f <- fg
                   ; pure (fmap (Choices . pure . Right) (f q)) })
        genSelectArrMaybeMapper

arbitrarySelectArrRecurse2 :: [TQ.Gen ArbitrarySelectArr]
arbitrarySelectArrRecurse2 =
    (fmap . fmap) ArbitrarySelectArr $
    map (\fg -> do { ArbitrarySelectArr q1 <- TQ.arbitrary
                   ; ArbitrarySelectArr q2 <- TQ.arbitrary
                   ; f <- fg
                   ; pure (OL.bilaterally f q1 q2) })
        genSelectMapper2
    ++
    (
    map (\fg -> do { ArbitrarySelectArr q1 <- TQ.arbitrary
                   ; ArbitrarySelectArr q2 <- TQ.arbitrary
                   ; f <- fg
                   ; pure (f q1 q2)
                   }) $
    genSelectArrPoly
    ++
    genSelectArrMapper2
    )

genSelect :: [TQ.Gen (O.Select Fields)]
genSelect =
    [ do
        ArbitraryHaskells fields_ <- TQ.arbitrary
        return ((pure . fieldsOfHaskells) fields_)
    , return        (fmap (\(x,y) -> Choices [Left (CInt x), Left (CInt y)])
                          (O.selectTable table1))
    , do
        TQ.oneof [
            do
            ArbitraryHaskellsList l <- TQ.arbitrary
            return (fmap fieldsList (O.valuesSafe (fmap O.toFields l)))
          , -- We test empty lists of values separately, because we
            -- used to not support them
            do
              l <- TQ.arbitrary
              let _ = l :: [()]
              return (fmap (const emptyChoices) (O.valuesSafe l))
          ]
    ]

genFieldsFunction :: [TQ.Gen (O.SelectArr Fields Fields)]
genFieldsFunction =
    [ do
        f                <- TQ.arbitrary
        return (Arrow.arr (unArbitraryFunction f))

    , do
        return restrictFirstBool
    ]

genSelectMapper :: [TQ.Gen (O.Select Fields -> O.Select Fields)]
genSelectMapper =
    [ do
        return (O.distinctExplicit distinctFields)
    , do
        l                <- TQ.choose (0, 100)
        return (O.limit l)
    , do
        l                <- TQ.choose (0, 100)
        return (O.offset l)
    , do
        o                <- TQ.arbitrary
        return (O.orderBy (arbitraryOrder o))

    , do
        return (O.aggregate aggregateFields)
    ]

genSelectMapper2 :: [TQ.Gen (O.Select Fields -> O.Select Fields
                                             -> O.Select Fields)]
genSelectMapper2 =
  [ do
      binaryOperation <- TQ.elements [ O.intersect
                                     , O.intersectAll
                                     , O.union
                                     , O.unionAll
                                     , O.except
                                     , O.exceptAll
                                     ]
      return (arbitraryBinary binaryOperation)
  ]
  where arbitraryBinary binaryOperation q1 q2 =
          (fmap fieldsList
            (binaryOperation
              (fmap listFields q1)
              (fmap listFields q2)))

genSelectArrMapper :: [TQ.Gen (O.SelectArr a Fields -> O.SelectArr a Fields)]
genSelectArrMapper =
    [ do
        thisLabel        <- TQ.arbitrary
        return (O.label thisLabel)
    , -- This is stupidly simple way of generating lateral subqueries.
      -- All it does is run a lateral aggregation.
      do
        return (fmap unpairColums
                . aggregateLaterally aggregateFields
                . fmap pairColumns)
    ]

genSelectArrMaybeMapper :: [TQ.Gen (O.SelectArr a Fields
                                    -> O.SelectArr a (O.MaybeFields Fields))]
genSelectArrMaybeMapper =
  [ do
      return OMF.optional
  ]

genSelectArrPoly :: [TQ.Gen (O.SelectArr a Fields
                             -> O.SelectArr a Fields
                             -> O.SelectArr a Fields)]
genSelectArrPoly =
    [ do
        pure (\q1 q2 -> appendChoices <$> q1 <*> q2)
    ]

genSelectArrMapper2 :: [TQ.Gen (O.SelectArr b c
                                -> O.SelectArr a b
                                -> O.SelectArr a c)]
genSelectArrMapper2 =
    [ do
        pure (<<<)
    ]

instance TQ.Arbitrary ArbitraryHaskells where
    arbitrary = arbitraryFields 6

-- Postgres strings cannot contain the zero codepoint.  See
--
-- https://www.postgresql.org/message-id/1171970019.3101.328.camel@coppola.muc.ecircle.de
arbitraryPGString :: TQ.Gen String
arbitraryPGString = filter (/= '\0') <$> TQ.arbitrary

arbitraryFields :: Int -> TQ.Gen ArbitraryHaskells
arbitraryFields size = do
      s <- TQ.choose (0, size)

      l <- TQ.vectorOf s (TQ.oneof
              [ Left  <$> CInt    <$> TQ.arbitrary
              , Left  <$> CBool   <$> TQ.arbitrary
              , Left  <$> CString <$> arbitraryPGString
              , pure (Right Nothing)
              , do
                  ArbitraryHaskells c <- arbitraryFields (size `div` 2)
                  return (Right (Just c))
              ])

      return (ArbitraryHaskells (Choices l))

instance TQ.Arbitrary ArbitraryHaskellsList where
  -- We don't want to choose very big lists because we take
  -- products of queries and so their sizes are going to end up
  -- multiplying.
  arbitrary = do
    k <- TQ.choose (0, 5)
    l <- TQ.vectorOf k $ do
      i <- TQ.arbitrary
      b <- TQ.arbitrary
      ms <- TQ.oneof [ pure Nothing
                     , Just <$> arbitraryPGString
                     ]
      pure (i, b, ms)
    return (ArbitraryHaskellsList l)

instance TQ.Arbitrary ArbitraryPositiveInt where
  arbitrary = fmap ArbitraryPositiveInt (TQ.choose (0, 100))

instance TQ.Arbitrary ArbitraryOrder where
  arbitrary = fmap ArbitraryOrder
                   (TQ.listOf ((,)
                               <$> TQ.oneof [return Asc, return Desc]
                               <*> TQ.choose (0, 100)))

odds :: Choices m i b s -> Choices m i b s
odds (Choices [])     = Choices []
odds (Choices (x:xs)) = Choices (x : unChoices (evens (Choices xs)))

evens :: Choices m i b s -> Choices m i b s
evens (Choices [])     = Choices []
evens (Choices (_:xs)) = odds (Choices xs)

pairColumns :: Choices m i b s -> (Choices m i b s, Choices m i b s)
pairColumns cs = (evens cs, odds cs)

unpairColums :: (Choices m i b s, Choices m i b s) -> Choices m i b s
unpairColums = uncurry appendChoices

instance TQ.Arbitrary ArbitraryFunction where
  arbitrary = do
    i <- TQ.choose (0 :: Int, 4)

    return (ArbitraryFunction (\xs ->
        if i == 0 then
          evens xs `appendChoices` odds xs
        else if i == 1 then
          evens xs `appendChoices` evens xs
        else if i == 2 then
          odds xs `appendChoices` odds xs
        else if i == 3 then
          evens xs
        else
          odds xs))

arbitraryOrder :: ArbitraryOrder -> O.Order Fields
arbitraryOrder =
  Monoid.mconcat
  . map (\(direction, index) ->
           (case direction of
              Asc  -> \f -> chooseChoice f (O.asc id) (O.asc id) (O.asc id)
              Desc -> \f -> chooseChoice f (O.desc id) (O.desc id) (O.desc id))
           -- If the list is empty we have to conjure up an arbitrary
           -- value of type Field.  We don't know how to order
           -- MaybeFields (yet) so we do the same if we hit a
           -- MaybeFields.
           (\c -> let l = unChoices c
                      len = length l
                  in if len > 0 then
                       case l !! (index `mod` length l) of
                         Left i  -> i
                         Right _ -> CInt 0
                  else
                       CInt 0))
  . unArbitraryOrder

arbitraryOrdering :: ArbitraryOrder -> Haskells -> Haskells -> Ord.Ordering
arbitraryOrdering =
  Monoid.mconcat
  . map (\(direction, index) ->
            (case direction of
                Asc  -> id
                Desc -> flip)
            -- If the list is empty we have to conjure up an arbitrary
            -- value of type Field.  We don't know how to order
            -- MaybeFields (yet) so we do the same if we hit a
            -- MaybeFields.
            --
            -- Note that this one will compare CInt Int
            -- to CBool Bool, but it never gets asked to
            -- do so, so we don't care.
            (Ord.comparing (\c -> let l = unChoices c
                                      len = length l
                                  in if len > 0 then
                                       case l !! (index `mod` length l) of
                                         Left i  -> i
                                         Right _ -> CInt 0
                                  else
                                       CInt 0)))
  . unArbitraryOrder

instance Functor (SelectArrDenotation a) where
  fmap f = SelectArrDenotation
           . (fmap . fmap . fmap . fmap) f
           . unSelectArrDenotation

pureList :: [a] -> SelectDenotation a
pureList = SelectArrDenotation . pure . pure . pure

instance Applicative (SelectArrDenotation a) where
  pure    = SelectArrDenotation . pure . pure . pure . pure
  f <*> x = SelectArrDenotation ((liftA2 . liftA2 . liftA2 . liftA2) ($)
                                   (unSelectArrDenotation f)
                                   (unSelectArrDenotation x))

instance Category SelectArrDenotation where
  id = SelectArrDenotation (\_ -> pure)
  (.) = \(SelectArrDenotation f) (SelectArrDenotation g) ->
          SelectArrDenotation (\conn -> f conn <=< g conn)

concatMapM :: Monad m => (a -> m [b]) -> [a] -> m [b]
concatMapM f = fmap concat . mapM f

denotationExplicit :: O.FromFields fields a
                   -> O.Select fields
                   -> SelectDenotation a
denotationExplicit qr q =
  SelectArrDenotation (\conn rs ->
    flip concatMapM rs (\() -> O.runSelectExplicit qr conn q))

denotation :: O.Select Fields -> SelectDenotation Haskells
denotation = denotationExplicit fromFieldsFields

denotationArr :: O.SelectArr FieldsTuple Fields
              -> SelectArrDenotation HaskellsTuple Haskells
denotationArr q =
  SelectArrDenotation (\conn hs ->
      let fs = O.valuesSafe (map O.toFields hs)
      in O.runSelectExplicit fromFieldsFields conn (q <<< fs))

denotation2 :: O.Select (Fields, Fields)
            -> SelectDenotation (Haskells, Haskells)
denotation2 = denotationExplicit (fromFieldsFields PP.***! fromFieldsFields)

denotationMaybeFields :: O.Select (O.MaybeFields Fields)
                      -> SelectDenotation (Maybe Haskells)
denotationMaybeFields =
  denotationExplicit (O.fromFieldsMaybeFields fromFieldsFields)

-- { Comparing the results

-- compareNoSort is stronger than compare so prefer to use it where
-- possible.  If the queries do not compare equal but do compare equal
-- sorted then switch to "compare".  That's no big deal.
compareNoSort :: (Ord a, Show a)
              => PGS.Connection
              -> SelectDenotation a
              -> SelectDenotation a
              -> IO TQ.Property
compareNoSort conn one two = do
  one' <- unSelectDenotation one conn
  two' <- unSelectDenotation two conn

  when (one' /= two')
       (putStrLn $ if sort one' == sort two'
                   then "[but they are equal sorted]"
                   else "AND THEY'RE NOT EVEN EQUAL SORTED!")

  return (one' === two')

compare :: (Show a, Ord a)
         => PGS.Connection
         -> SelectDenotation a
         -> SelectDenotation a
         -> IO TQ.Property
compare conn one two = do
  one' <- unSelectDenotation one conn
  two' <- unSelectDenotation two conn
  return (sort one' === sort two')

compareSortedBy :: Ord a
                => (a -> a -> Ord.Ordering)
                -> PGS.Connection
                -> SelectDenotation a
                -> SelectDenotation a
                -> IO Bool
compareSortedBy o conn one two = do
  one' <- unSelectDenotation one conn
  two' <- unSelectDenotation two conn
  return ((sort one' == sort two')
          && isSortedBy o one')

-- }

-- { The tests

fields :: PGS.Connection -> ArbitraryHaskells -> IO TQ.Property
fields conn (ArbitraryHaskells c) =
  compareNoSort conn (denotation (pure (fieldsOfHaskells c)))
                     (pure c)

compose :: PGS.Connection
        -> ArbitrarySelectArr
        -> ArbitrarySelect
        -> IO TQ.Property
compose conn (ArbitrarySelectArr a) (ArbitrarySelect q) = do
  compare conn (denotation (a' . Arrow.arr listFields . q))
               (denotationArr a' . fmap listHaskells (denotation q))
    where a' = a . Arrow.arr fieldsList


-- Would prefer to write 'compare conn (denotation id) id' but that
-- requires extending compare to compare SelectArrs.
identity :: PGS.Connection
         -> ArbitrarySelect
         -> IO TQ.Property
identity conn (ArbitrarySelect q) = do
  compare conn (denotation (id . q))
               (id . denotation q)

fmap' :: PGS.Connection -> ArbitraryFunction -> ArbitrarySelect -> IO TQ.Property
fmap' conn f (ArbitrarySelect q) =
  compareNoSort conn (denotation (fmap (unArbitraryFunction f) q))
                     (onList (fmap (unArbitraryFunction f)) (denotation q))

apply :: PGS.Connection -> ArbitrarySelect -> ArbitrarySelect -> IO TQ.Property
apply conn (ArbitrarySelect q1) (ArbitrarySelect q2) =
  compare conn (denotation2 ((,) <$> q1 <*> q2))
                ((,) <$> denotation q1 <*> denotation q2)

-- When combining arbitrary queries with the applicative product <*>
-- the limit of the denotation is not always the denotation of the
-- limit.  Without some ordering applied before the limit the returned
-- rows can vary.  If an ordering is applied beforehand we can check
-- the invariant that the returned rows always compare smaller than
-- the remainder under the applied ordering.
--
-- Strangely the same caveat doesn't apply to offset.
limit :: PGS.Connection
      -> ArbitraryPositiveInt
      -> ArbitrarySelect
      -> ArbitraryOrder
      -> IO Bool
limit conn (ArbitraryPositiveInt l) (ArbitrarySelect q) o = do
  let q' = O.limit l (O.orderBy (arbitraryOrder o) q)

  one' <- unSelectDenotation (denotation q') conn
  two' <- unSelectDenotation (denotation q) conn

  let remainder = MultiSet.fromList two'
                  `MultiSet.difference`
                  MultiSet.fromList one'
      maxChosen :: Maybe Haskells
      maxChosen = maximumBy (arbitraryOrdering o) one'
      minRemain :: Maybe Haskells
      minRemain = minimumBy (arbitraryOrdering o) (MultiSet.toList remainder)
      cond :: Maybe Bool
      cond = lteBy (arbitraryOrdering o) <$> maxChosen <*> minRemain
      condBool :: Bool
      condBool = Maybe.fromMaybe True cond

  return ((length one' == min l (length two'))
          && condBool)

offset :: PGS.Connection -> ArbitraryPositiveInt -> ArbitrarySelect
       -> IO TQ.Property
offset conn (ArbitraryPositiveInt l) (ArbitrarySelect q) =
  compareNoSort conn (denotation (O.offset l q))
                     (onList (drop l) (denotation q))

order :: PGS.Connection -> ArbitraryOrder -> ArbitrarySelect -> IO Bool
order conn o (ArbitrarySelect q) =
  compareSortedBy (arbitraryOrdering o)
                  conn
                  (denotation (O.orderBy (arbitraryOrder o) q))
                  (denotation q)

distinct :: PGS.Connection -> ArbitrarySelect -> IO TQ.Property
distinct conn (ArbitrarySelect q) =
  compare conn (denotation (O.distinctExplicit distinctFields q))
                (onList nub (denotation q))

-- When we added <*> to the arbitrary queries we started getting some
-- consequences to do with the order of the returned rows and so
-- restrict had to start being compared sorted.
restrict :: PGS.Connection -> ArbitrarySelect -> IO TQ.Property
restrict conn (ArbitrarySelect q) =
  compare conn (denotation (restrictFirstBool <<< q))
                (onList restrictFirstBoolList (denotation q))

values :: PGS.Connection -> ArbitraryHaskellsList -> IO TQ.Property
values conn (ArbitraryHaskellsList l) =
  compareNoSort conn
                (denotation (fmap fieldsList (O.valuesSafe (fmap O.toFields l))))
                (pureList (fmap fieldsList l))

-- We test values entries of length two in values, and values entries
-- of length zero here.  Ideally we would find some way to merge them.
valuesEmpty :: PGS.Connection -> [()] -> IO TQ.Property
valuesEmpty conn l =
  compareNoSort conn
                (denotationExplicit D.def (O.valuesSafe l))
                (pureList l)

aggregate :: PGS.Connection -> ArbitrarySelect -> IO TQ.Property
aggregate conn (ArbitrarySelect q) =
  compareNoSort conn (denotation (O.aggregate aggregateFields q))
                     (onList aggregateDenotation (denotation q))


label :: PGS.Connection -> String -> ArbitrarySelect -> IO TQ.Property
label conn comment (ArbitrarySelect q) =
  compareNoSort conn (denotation (O.label comment q))
                     (denotation q)

optional :: PGS.Connection -> ArbitrarySelect -> IO TQ.Property
optional conn (ArbitrarySelect q) =
  compare conn (denotationMaybeFields (OMF.optional q))
               (onList optionalDenotation (denotation q))

maybeFieldsToSelect :: PGS.Connection -> ArbitrarySelectMaybe -> IO TQ.Property
maybeFieldsToSelect conn (ArbitrarySelectMaybe q) =
  compare conn (denotation (O.maybeFieldsToSelect <<< q))
               (onList (Maybe.maybeToList =<<) (denotationMaybeFields q))

traverseMaybeFields :: PGS.Connection
                    -> ArbitrarySelectArr
                    -> ArbitrarySelectMaybe
                    -> IO TQ.Property
traverseMaybeFields conn (ArbitrarySelectArr q) (ArbitrarySelectMaybe qm) =
  compare conn
    (denotationMaybeFields (travMF q' . Arrow.arr (fmap listFields) . qm))
    (traverseDenotation (denotationArr q')
       ((fmap . fmap) listHaskells (denotationMaybeFields qm)))
  where u = unpackFields
        q' = q . Arrow.arr fieldsList
        travMF = O.traverseMaybeFieldsExplicit D.def u


{- TODO

  * Nullability
  * Operators (mathematical, logical, etc.)
  * Use traverseMaybeFields in generated queries

-}

-- }

-- { Running the QuickCheck

-- One way that the property tests can fail is because of LIMIT and
-- OFFSET.  It seems that a query returning LIMIT or OFFSET does not
-- always return the same result when it is part of a larger query.
-- This happens rarely.  We could sort before LIMIT or OFFSET to make
-- it even rarer.
--
-- Another way is "resource vanished".  That's not our fault.  That's
-- Postgres segfaulting on perfectly good queries.

run :: PGS.Connection -> IO ()
run conn = do

  let prop1 :: TQ.Testable prop
            => (PGS.Connection -> a -> IO prop)
            -> a -> TQ.Property
      prop1 p = fmap          TQ.ioProperty (p conn)
      prop2 :: TQ.Testable prop
            => (PGS.Connection -> a -> b -> IO prop)
            -> a -> b -> TQ.Property
      prop2 p = (fmap . fmap) TQ.ioProperty (p conn)
      prop3 :: TQ.Testable prop
            => (PGS.Connection -> a -> b -> c -> IO prop)
            -> a -> b -> c -> TQ.Property
      prop3 p = (fmap . fmap . fmap) TQ.ioProperty (p conn)

      test1 :: (Show a, TQ.Arbitrary a, TQ.Testable prop)
               => (PGS.Connection -> a -> IO prop) -> IO ()
      test1 = t . prop1

      test2 :: (Show a1, Show a2, TQ.Arbitrary a1, TQ.Arbitrary a2,
                TQ.Testable prop)
               => (PGS.Connection -> a1 -> a2 -> IO prop) -> IO ()
      test2 = t . prop2

      test3 :: (Show a1, Show a2, Show a3,
                TQ.Arbitrary a1, TQ.Arbitrary a2, TQ.Arbitrary a3,
                TQ.Testable prop)
               => (PGS.Connection -> a1 -> a2 -> a3 -> IO prop) -> IO ()
      test3 = t . prop3

      t p = errorIfNotSuccess
        =<< TQ.quickCheckWithResult (TQ.stdArgs { TQ.maxSuccess = 1000 }) p

  test1 identity
  test2 compose
  test1 fields
  test2 fmap'
  test2 apply
  test3 limit
  test2 offset
  test2 order
  test1 distinct
  test1 restrict
  test1 values
  test1 valuesEmpty
  test1 aggregate
  test2 label
  test1 optional
  test1 maybeFieldsToSelect
  test2 traverseMaybeFields

-- }

-- { Utilities

nub :: Ord a => [a] -> [a]
nub = Set.toList . Set.fromList

choicePP :: PP.SumProfunctor p
         => p i1 i2 -> p b1 b2 -> p s1 s2
         -> p (Choice i1 b1 s1) (Choice i2 b2 s2)
choicePP p1 p2 p3 = asSumProfunctor $ proc choice -> case choice of
  CInt i    -> constructor CInt    p1 -< i
  CBool b   -> constructor CBool   p2 -< b
  CString s -> constructor CString p3 -< s

defChoicesPP :: (D.Default p a a', D.Default p b b', D.Default p s s',
                 PP.SumProfunctor p, PP.ProductProfunctor p)
             => (p (Choices m a b s) (Choices m' a' b' s')
                -> p (m (Choices m a b s)) (m' (Choices m' a' b' s')))
             -> p (Choices m a b s) (Choices m' a' b' s')
defChoicesPP = ppChoices defChoicePP

defChoicePP :: (D.Default p a a', D.Default p b b', D.Default p s s',
                PP.SumProfunctor p, PP.ProductProfunctor p)
            => p (Choice a b s) (Choice a' b' s')
defChoicePP = choicePP D.def D.def D.def

-- Replace this with `isSuccess` when the following issue is fixed
--
--     https://github.com/nick8325/quickcheck/issues/220
errorIfNotSuccess :: TQ.Result -> IO ()
errorIfNotSuccess r = case r of
  TQ.Success {} -> return ()
  _             -> error "Failed"

-- We could try to be clever and look inside the MaybeFields, but this
-- will do for now.
firstBoolOrTrue :: b -> Choices m a b s -> (b, Choices m a b s)
firstBoolOrTrue true c = (b, c)
  where b = case Maybe.mapMaybe (either isBool (const Nothing)) (unChoices c) of
          []    -> true
          (x:_) -> x

-- We could try to be clever and look inside the MaybeFields, but this
-- will do for now.
firstIntOr :: a -> Choices m a b s -> (a, Choices m a b s)
firstIntOr else_ c = (b, c)
  where b = case Maybe.mapMaybe (either isInt (const Nothing)) (unChoices c) of
          []    -> else_
          (x:_) -> x

-- We could try to be clever and look inside the MaybeFields, but this
-- will do for now.
firstStringOr :: s -> Choices m a b s -> (s, Choices m a b s)
firstStringOr else_ c = (b, c)
  where b = case Maybe.mapMaybe (either isString (const Nothing)) (unChoices c) of
          []    -> else_
          (x:_) -> x

firstMaybe :: Choices m a b s
           -> Maybe (m (Choices m a b s))
firstMaybe c = case Maybe.mapMaybe (either (const Nothing) Just) (unChoices c) of
          []    -> Nothing
          (x:_) -> Just x

isBool :: Choice a b s -> Maybe b
isBool (CInt _)  = Nothing
isBool (CBool l) = Just l
isBool (CString _) = Nothing

isInt :: Choice a b s -> Maybe a
isInt (CInt a)  = Just a
isInt (CBool _) = Nothing
isInt (CString _) = Nothing

isString :: Choice a b s -> Maybe s
isString (CInt _)  = Nothing
isString (CBool _) = Nothing
isString (CString s) = Just s

fieldsToMaybeFields :: Applicative m => Choices m i b s -> m (Choices m i b s)
fieldsToMaybeFields fs = case Maybe.listToMaybe (subMaybeFields fs) of
  Nothing -> pure fs
  Just x  -> x

subMaybeFields :: Choices m i b s -> [m (Choices m i b s)]
subMaybeFields = unChoices >>> Maybe.mapMaybe (\case Left _  -> Nothing
                                                     Right r -> Just r)

restrictFirstBool :: O.SelectArr Fields Fields
restrictFirstBool = Arrow.arr snd
      <<< Arrow.first O.restrict
      <<< Arrow.arr (firstBoolOrTrue (O.sqlBool True))

restrictFirstBoolList :: [Haskells] -> [Haskells]
restrictFirstBoolList = map snd
                        . filter fst
                        . map (firstBoolOrTrue True)

isSortedBy ::(a -> a -> Ord.Ordering) -> [a] -> Bool
isSortedBy comp xs = all (uncurry (.<=)) (zip xs (tail' xs))
  where tail' []     = []
        tail' (_:ys) = ys
        x .<= y       = lteBy comp x y

lteBy :: (a -> a -> Ord.Ordering) -> a -> a -> Bool
lteBy comp x y = comp x y /= Ord.GT

maximumBy :: (a -> a -> Ord.Ordering) -> [a] -> Maybe a
maximumBy _ []       = Nothing
maximumBy c xs@(_:_) = Just (List.maximumBy c xs)

minimumBy :: (a -> a -> Ord.Ordering) -> [a] -> Maybe a
minimumBy = maximumBy . flip

-- }
