module Language.SMTLib2.Internals.Embed where

import Language.SMTLib2.Internals.Backend as B
import Language.SMTLib2.Internals.Type
import Language.SMTLib2.Internals.Type.Nat
import Language.SMTLib2.Internals.Expression
import Language.SMTLib2.Internals.Monad

import Data.GADT.Show
import Data.GADT.Compare
import Data.Proxy
import Data.Typeable
import Data.Constraint
import qualified Data.Map.Strict as Map

class (Backend (EmbedBackend e),GShow e) => Embed e where
  type EmbedBackend e :: *
  type EmbedSub e :: Type -> *
  embed :: GetType tp
        => Expression (Var (EmbedBackend e))
                      (QVar (EmbedBackend e))
                      (Fun (EmbedBackend e))
                      (B.Constr (EmbedBackend e))
                      (B.Field (EmbedBackend e))
                      (FunArg (EmbedBackend e)) e tp
        -> e tp
  embedQuantifier :: GetTypes arg => Quantifier
                  -> (Args e arg -> e BoolType)
                  -> e BoolType
  embedConstant :: (ToSMT c,FromSMT (ValueRepr c),ValueType (ValueRepr c) ~ c)
                => c -> e (ValueRepr c)
  embedConstrTest :: IsDatatype dt => String -> Proxy dt -> e (DataType dt) -> e BoolType
  embedGetField :: (IsDatatype dt,GetType tp)
                => String -> String -> Proxy dt -> Proxy tp
                -> e (DataType dt) -> e tp
  extract :: GetType tp
          => e tp
          -> Either (Expression (Var (EmbedBackend e))
                                (QVar (EmbedBackend e))
                                (Fun (EmbedBackend e))
                                (B.Constr (EmbedBackend e))
                                (B.Field (EmbedBackend e))
                                (FunArg (EmbedBackend e)) e tp)
                    (EmbedSub e tp)
  encodeSub :: GetType tp => Proxy e -> EmbedSub e tp
            -> SMT (EmbedBackend e) (Expr (EmbedBackend e) tp)
  extractSub :: Expr (EmbedBackend e) tp -> SMT (EmbedBackend e) (Maybe (e tp))

class (GetType repr,ToSMT (ValueType repr),ValueRepr (ValueType repr) ~ repr) => FromSMT repr where
  type ValueType repr :: *
  fromValue :: (Typeable con,GCompare con,Typeable field)
            => DatatypeInfo con field -> Value con repr -> ValueType repr

class (Typeable tp,Show tp,Ord tp) => ToSMT tp where
  type ValueRepr tp :: Type
  toValue :: (Typeable con,Typeable field)
          => DatatypeInfo con field -> tp -> Value con (ValueRepr tp)
  toSMTCtx :: Proxy tp -> Dict (FromSMT (ValueRepr tp),ValueType (ValueRepr tp) ~ tp)

instance FromSMT BoolType where
  type ValueType BoolType = Bool
  fromValue _ (BoolValue b) = b

instance ToSMT Bool where
  type ValueRepr Bool = BoolType
  toValue _ b = BoolValue b
  toSMTCtx _ = Dict

instance FromSMT IntType where
  type ValueType IntType = Integer
  fromValue _ (IntValue i) = i

instance ToSMT Integer where
  type ValueRepr Integer = IntType
  toValue _ i = IntValue i
  toSMTCtx _ = Dict

instance FromSMT RealType where
  type ValueType RealType = Rational
  fromValue _ (RealValue v) = v

instance ToSMT Rational where
  type ValueRepr Rational = RealType
  toValue _ v = RealValue v
  toSMTCtx _ = Dict

newtype SMTBV (bw::Nat) = SMTBV Integer deriving (Show,Eq,Ord)

instance KnownNat n => FromSMT (BitVecType n) where
  type ValueType (BitVecType n) = SMTBV n
  fromValue _ (BitVecValue v) = SMTBV v

instance KnownNat n => ToSMT (SMTBV n) where
  type ValueRepr (SMTBV n) = BitVecType n
  toValue _ (SMTBV v) = BitVecValue v
  toSMTCtx _ = Dict

data DT dt = DT dt deriving (Show,Eq,Ord)

instance (IsDatatype dt) => FromSMT (DataType dt) where
  type ValueType (DataType dt) = (DT dt)
  fromValue info (ConstrValue con args :: Value con (DataType dt))
    = case Map.lookup (typeOf (Proxy::Proxy dt)) info of
        Just (RegisteredDT rdt) -> case castReg rdt of
          Just (rdt'::B.BackendDatatype con field '(DatatypeSig dt,dt))
            -> findConstr info con args (bconstructors rdt')
    where
      castReg :: (Typeable con,Typeable field,
                  Typeable dt,Typeable dt',
                  Typeable (DatatypeSig dt),Typeable (DatatypeSig dt'))
              => B.BackendDatatype con field '(DatatypeSig dt',dt')
              -> Maybe (B.BackendDatatype con field '(DatatypeSig dt,dt))
      castReg = cast

      findConstr :: (Typeable con,GEq con,Typeable field,GetTypes arg)
                 => DatatypeInfo con field
                 -> con '(arg,dt) -> Args (Value con) arg
                 -> Constrs (B.BackendConstr con field) sig dt
                 -> DT dt
      findConstr info con args (ConsCon con' cons)
        = case geq con (bconRepr con') of
            Just Refl -> DT (bconstruct con' (transArgs info args))
            Nothing -> findConstr info con args cons

      castCon :: (Typeable con,Typeable field,Typeable arg,Typeable arg',Typeable dt)
              => B.BackendConstr con field '(arg,dt)
              -> Maybe (B.BackendConstr con field '(arg',dt))
      castCon = cast

      transArgs :: Typeable field => DatatypeInfo con field
                -> Args (Value con) arg -> Args ConcreteValue arg
      transArgs info NoArg = NoArg
      transArgs info (Arg v vs) = Arg (transArg info v) (transArgs info vs)

      transArg :: Typeable field => DatatypeInfo con field -> Value con t -> ConcreteValue t
      transArg info (BoolValue b) = BoolValueC b
      transArg info (IntValue v) = IntValueC v
      transArg info (RealValue v) = RealValueC v
      transArg info (BitVecValue v) = BitVecValueC v
      transArg info val@(ConstrValue con args) = let DT v = fromValue info val
                                                 in ConstrValueC v

instance IsDatatype dt => ToSMT (DT dt) where
  type ValueRepr (DT dt) = DataType dt
  toValue info (DT (dt::dt)) = case Map.lookup (typeOf (Proxy::Proxy dt)) info of
    Just (RegisteredDT rdt) -> case castReg rdt of
      Just (rdt'::B.BackendDatatype con field '(DatatypeSig dt,dt))
        -> findConstr info dt (bconstructors rdt')
    where
      findConstr :: (Typeable con,Typeable field)
                 => DatatypeInfo con field
                 -> dt -> Constrs (B.BackendConstr con field) sig dt
                 -> Value con (DataType dt)
      findConstr info dt (ConsCon con cons)
        = if bconTest con dt
          then ConstrValue (bconRepr con) (extractVal info dt (bconFields con))
          else findConstr info dt cons

      castReg :: (Typeable con,Typeable field,
                  Typeable dt,Typeable dt',
                  Typeable (DatatypeSig dt),Typeable (DatatypeSig dt'))
              => B.BackendDatatype con field '(DatatypeSig dt',dt')
              -> Maybe (B.BackendDatatype con field '(DatatypeSig dt,dt))
      castReg = cast

      extractVal :: (Typeable con,Typeable field)
                 => DatatypeInfo con field
                 -> dt -> Args (B.BackendField field dt) arg
                 -> Args (Value con) arg
      extractVal info dt NoArg = NoArg
      extractVal info dt (Arg f fs) = Arg (transVal info $ bfieldGet f dt)
                                          (extractVal info dt fs)

      transVal :: (Typeable con,Typeable field)
               => DatatypeInfo con field
               -> ConcreteValue t
               -> Value con t
      transVal _ (BoolValueC b) = BoolValue b
      transVal _ (IntValueC v) = IntValue v
      transVal _ (RealValueC v) = RealValue v
      transVal _ (BitVecValueC v) = BitVecValue v
      transVal info (ConstrValueC v)
        = toValue info (DT v)
  toSMTCtx _ = Dict