{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}

-- |
-- Module      : Database.Relational.Query.TH
-- Copyright   : 2013 Kei Hibino
-- License     : BSD3
--
-- Maintainer  : ex8k.hibino@gmail.com
-- Stability   : experimental
-- Portability : unknown
--
-- This module defines templates for Haskell record type and type class instances
-- to define column projection on SQL query like Haskell records.
-- Templates are generated by also using functions of "Database.Record.TH" module,
-- so mapping between list of untyped SQL type and Haskell record type will be done too.
module Database.Relational.Query.TH (
  -- * All templates about table
  defineTableDefault',
  defineTableDefault,

  -- * Inlining typed 'Query'
  inlineQuery,

  -- * Column projections and basic 'Relation' for Haskell record
  defineTableTypesAndRecordDefault,

  -- * Constraint key templates
  defineHasPrimaryKeyInstance,
  defineHasPrimaryKeyInstanceDefault,
  defineHasNotNullKeyInstance,
  defineHasNotNullKeyInstanceDefault,

  -- * Column projections
  defineColumn, defineColumnDefault,

  -- * Table metadata type and basic 'Relation'
  defineTableTypes, defineTableTypesDefault,

  -- * Basic SQL templates generate rules
  definePrimaryQuery,
  definePrimaryUpdate,
  defineInsert,

  -- * Var expression templates
  tableVarExpDefault,
  relationVarExpDefault,

  -- * Derived SQL templates from table definitions
  defineSqlsWithPrimaryKey,
  defineSqls,
  defineSqlsWithPrimaryKeyDefault,
  defineSqlsDefault
  ) where

import Data.Char (toUpper, toLower)
import Data.List (foldl1')

import Language.Haskell.TH
  (Q, reify, Info (VarI), TypeQ, Type (AppT, ConT), ExpQ,
   tupleT, appT, Dec, stringE, listE)
import Language.Haskell.TH.Name.CamelCase
  (VarName, varName, ConName, varNameWithPrefix, varCamelcaseName, toVarExp)
import Language.Haskell.TH.Lib.Extra
  (compileError, simpleValD, maybeD, integralE)

import Database.Record.TH
  (recordTypeDefault,
   defineRecordTypeDefault,
   defineHasColumnConstraintInstance)
import qualified Database.Record.TH as Record
import Database.Record.Instances ()

import Database.Relational.Query
  (Table, Pi, Relation,
   sqlFromRelation, Query, relationalQuery, KeyUpdate, Insert, typedInsert,
   HasConstraintKey(constraintKey), projectionKey, Primary, NotNull)
import qualified Database.Relational.Query as Query

import Database.Relational.Query.Constraint (Key, unsafeDefineConstraintKey)
import qualified Database.Relational.Query.Table as Table
import Database.Relational.Query.Type (unsafeTypedQuery)
import qualified Database.Relational.Query.Pi.Unsafe as UnsafePi
import Database.Relational.Query.Derives (primary, primaryUpdate)


-- | Rule template to infer constraint key.
defineHasConstraintKeyInstance :: TypeQ   -- ^ Constraint type
                               -> TypeQ   -- ^ Record type
                               -> TypeQ   -- ^ Key type
                               -> [Int]   -- ^ Indexes specifies key
                               -> Q [Dec] -- ^ Result 'HasConstraintKey' declaration
defineHasConstraintKeyInstance constraint recType colType indexes = do
  -- kc <- defineHasColumnConstraintInstance constraint recType index
  ck <- [d| instance HasConstraintKey $constraint $recType $colType  where
              constraintKey = unsafeDefineConstraintKey $(listE [integralE ix | ix <- indexes])
          |]
  return ck

-- | Rule template to infer primary key.
defineHasPrimaryKeyInstance :: TypeQ   -- ^ Record type
                            -> TypeQ   -- ^ Key type
                            -> [Int]   -- ^ Indexes specifies key
                            -> Q [Dec] -- ^ Result constraint key declarations
defineHasPrimaryKeyInstance recType colType indexes = do
  kc <- Record.defineHasPrimaryKeyInstance recType indexes
  ck <- defineHasConstraintKeyInstance [t| Primary |] recType colType indexes
  return $ kc ++ ck

-- | Rule template to infer primary key.
defineHasPrimaryKeyInstanceDefault :: String  -- ^ Table name
                                   -> TypeQ   -- ^ Column type
                                   -> [Int]   -- ^ Primary key index
                                   -> Q [Dec] -- ^ Declarations of primary constraint key
defineHasPrimaryKeyInstanceDefault =
  defineHasPrimaryKeyInstance . recordTypeDefault

-- | Rule template to infer not-null key.
defineHasNotNullKeyInstance :: TypeQ   -- ^ Record type
                            -> Int     -- ^ Column index
                            -> Q [Dec] -- ^ Result 'ColumnConstraint' declaration
defineHasNotNullKeyInstance =
  defineHasColumnConstraintInstance [t| NotNull |]

-- | Rule template to infer not-null key.
defineHasNotNullKeyInstanceDefault :: String  -- ^ Table name
                                   -> Int     -- ^ NotNull key index
                                   -> Q [Dec] -- ^ Declaration of not-null constraint key
defineHasNotNullKeyInstanceDefault =
  defineHasNotNullKeyInstance . recordTypeDefault


-- | Column projection path 'Pi' template.
defineColumn' :: TypeQ   -- ^ Record type
              -> VarName -- ^ Column declaration variable name
              -> Int     -- ^ Column index in record (begin with 0)
              -> TypeQ   -- ^ Column type
              -> Q [Dec] -- ^ Column projection path declaration
defineColumn' recType var' i colType = do
  let var = varName var'
  simpleValD var [t| Pi $recType $colType |]
    [| UnsafePi.definePi $(integralE i) |]

-- | Column projection path 'Pi' and constraint key template.
defineColumn :: Maybe (TypeQ, VarName) -- ^ May Constraint type and constraint object name
             -> TypeQ                  -- ^ Record type
             -> VarName                -- ^ Column declaration variable name
             -> Int                    -- ^ Column index in record (begin with 0)
             -> TypeQ                  -- ^ Column type
             -> Q [Dec]                -- ^ Column projection path declaration
defineColumn mayConstraint recType var' i colType = do
  maybe
    (defineColumn' recType var' i colType)
    ( \(constraint, cname') -> do
         let cname = varName cname'
         ck  <- simpleValD cname [t| Key $constraint $recType $colType |]
                [| unsafeDefineConstraintKey $(integralE i) |]

         col <- simpleValD (varName var') [t| Pi $recType $colType |]
                [| projectionKey $(toVarExp cname') |]
         return $ ck ++ col)
    mayConstraint

-- | Make column projection path and constraint key template using default naming rule.
defineColumnDefault :: Maybe TypeQ -- ^ May Constraint type
                    -> TypeQ       -- ^ Record type
                    -> String      -- ^ Column name
                    -> Int         -- ^ Column index in record (begin with 0)
                    -> TypeQ       -- ^ Column type
                    -> Q [Dec]     -- ^ Column declaration
defineColumnDefault mayConstraint recType name =
  defineColumn (fmap withCName mayConstraint) recType varN
  where varN        = varCamelcaseName (name ++ "'")
        withCName t = (t, varCamelcaseName (name ++ "_constraint"))

-- | 'Table' and 'Relation' templates.
defineTableTypes :: VarName                          -- ^ Table declaration variable name
                 -> VarName                          -- ^ Relation declaration variable name
                 -> TypeQ                            -- ^ Record type
                 -> String                           -- ^ Table name in SQL ex. FOO_SCHEMA.table0
                 -> [((String, TypeQ), Maybe TypeQ)] -- ^ Column names and types and constraint type
                 -> Q [Dec]                          -- ^ Table and Relation declaration
defineTableTypes tableVar' relVar' recordType table columns = do
  let tableVar = varName tableVar'
  tableDs <- simpleValD tableVar [t| Table $(recordType) |]
            [| Table.table $(stringE table) $(listE $ map stringE (map (fst . fst) columns)) |]
  let relVar   = varName relVar'
  relDs   <- simpleValD relVar   [t| Relation () $(recordType) |]
             [| Query.table $(toVarExp tableVar') |]
  return $ tableDs ++ relDs

tableSQL :: String -> String -> String
tableSQL schema table = map toUpper schema ++ '.' : map toLower table

tableVarNameDefault :: String -> VarName
tableVarNameDefault =  (`varNameWithPrefix` "tableOf")

-- | Make 'Table' variable expression template from table name using default naming rule.
tableVarExpDefault :: String -- ^ Table name string
                   -> ExpQ -- ^ Result var Exp
tableVarExpDefault =  toVarExp . tableVarNameDefault

relationVarNameDefault :: String -> VarName
relationVarNameDefault =  varCamelcaseName

-- | Make 'Relation' variable expression template from table name using default naming rule.
relationVarExpDefault :: String -- ^ Table name string
                      -> ExpQ -- ^ Result var Exp
relationVarExpDefault =  toVarExp . relationVarNameDefault

-- | Make templates about table and column metadatas using default naming rule.
defineTableTypesDefault :: String                           -- ^ Schema name
                        -> String                           -- ^ Table name
                        -> [((String, TypeQ), Maybe TypeQ)] -- ^ Column names and types and constraint type
                        -> Q [Dec]                          -- ^ Result declarations
defineTableTypesDefault schema table columns = do
  let recordType = recordTypeDefault table
  tableDs <- defineTableTypes
             (tableVarNameDefault table)
             (relationVarNameDefault table)
             recordType
             (tableSQL schema table)
             columns
  let defCol i ((name, typ), constraint) = defineColumnDefault constraint recordType name i typ
  colsDs  <- fmap concat . sequence . zipWith defCol [0..] $ columns
  return $ tableDs ++ colsDs

-- | Make templates about table, column and haskell record using default naming rule.
defineTableTypesAndRecordDefault :: String            -- ^ Schema name
                                 -> String            -- ^ Table name
                                 -> [(String, TypeQ)] -- ^ Column names and types
                                 -> [ConName]         -- ^ Record derivings
                                 -> Q [Dec]           -- ^ Result declarations
defineTableTypesAndRecordDefault schema table columns drives = do
  recD    <- defineRecordTypeDefault table columns drives
  tableDs <- defineTableTypesDefault schema table [(c, Nothing) | c <- columns ]
  return $ recD ++ tableDs

-- | Template of derived primary 'Query'.
definePrimaryQuery :: VarName -- ^ Variable name of result declaration
                   -> TypeQ   -- ^ Parameter type of 'Query'
                   -> TypeQ   -- ^ Record type of 'Query'
                   -> ExpQ    -- ^ 'Relation' expression
                   -> Q [Dec] -- ^ Result 'Query' declaration
definePrimaryQuery toDef' paramType recType relE = do
  let toDef = varName toDef'
  simpleValD toDef
    [t| Query $paramType $recType |]
    [|  relationalQuery (primary $relE) |]

-- | Template of derived primary 'Update'.
definePrimaryUpdate :: VarName -- ^ Variable name of result declaration
                    -> TypeQ   -- ^ Parameter type of 'Update'
                    -> TypeQ   -- ^ Record type of 'Update'
                    -> ExpQ    -- ^ 'Table' expression
                    -> Q [Dec] -- ^ Result 'Update' declaration
definePrimaryUpdate toDef' paramType recType tableE = do
  let toDef = varName toDef'
  simpleValD toDef
    [t| KeyUpdate $paramType $recType |]
    [|  primaryUpdate $tableE |]


-- | Template of 'Insert'.
defineInsert :: VarName -- ^ Variable name of result declaration
             -> TypeQ   -- ^ Record type of 'Insert'
             -> ExpQ    -- ^ 'Table' expression
             -> Q [Dec] -- ^ Result 'Insert' declaration
defineInsert toDef' recType tableE = do
  let toDef = varName toDef'
  simpleValD toDef
    [t| Insert $recType |]
    [|  typedInsert $tableE |]

-- | SQL templates derived from primary key.
defineSqlsWithPrimaryKey :: VarName -- ^ Variable name of select query definition from primary key
                         -> VarName -- ^ Variable name of update statement definition from primary key
                         -> TypeQ   -- ^ Primary key type
                         -> TypeQ   -- ^ Record type
                         -> ExpQ    -- ^ Relation expression
                         -> ExpQ    -- ^ Table expression
                         -> Q [Dec] -- ^ Result declarations
defineSqlsWithPrimaryKey sel upd paramType recType relE tableE = do
  selD <- definePrimaryQuery  sel paramType recType relE
  updD <- definePrimaryUpdate upd paramType recType tableE
  return $ selD ++ updD

-- | SQL templates for 'Table'.
defineSqls :: VarName -- ^ Variable name of 'Insert' declaration
           -> TypeQ   -- ^ Record type
           -> ExpQ    -- ^ 'Table' expression
           -> Q [Dec] -- ^ Result declarations
defineSqls =  defineInsert

-- | SQL templates derived from primary key using default naming rule.
defineSqlsWithPrimaryKeyDefault :: String  -- ^ Table name of Database
                                -> TypeQ   -- ^ Primary key type
                                -> TypeQ   -- ^ Record type
                                -> ExpQ    -- ^ Relation expression
                                -> ExpQ    -- ^ Table expression
                                -> Q [Dec] -- ^ Result declarations
defineSqlsWithPrimaryKeyDefault table  =
  defineSqlsWithPrimaryKey sel upd
  where
    sel = table `varNameWithPrefix` "select"
    upd = table `varNameWithPrefix` "update"

-- | SQL templates for 'Table' using default naming rule.
defineSqlsDefault :: String  -- ^ Table name string
                  -> TypeQ   -- ^ Record type
                  -> ExpQ    -- ^ 'Table' expression
                  -> Q [Dec] -- ^ Result declarations
defineSqlsDefault table =
  defineSqls
    (table `varNameWithPrefix` "insert")

-- | Generate all templates about table except for constraint keys using default naming rule.
defineTableDefault' :: String            -- ^ Schema name of Database
                    -> String            -- ^ Table name of Database
                    -> [(String, TypeQ)] -- ^ Column names and types
                    -> [ConName]         -- ^ derivings for Record type
                    -> Q [Dec]           -- ^ Result declarations
defineTableDefault' schema table columns derives = do
  recD <- defineTableTypesAndRecordDefault schema table columns derives
  let recType = recordTypeDefault table
      tableE  = tableVarExpDefault table
  sqlD <- defineSqlsDefault table recType tableE
  return $ recD ++ sqlD

-- | All templates about primary key.
defineWithPrimaryKeyDefault :: String  -- ^ Table name string
                            -> TypeQ   -- ^ Type of primary key
                            -> [Int]   -- ^ Indexes specifies primary key
                            -> Q [Dec] -- ^ Result declarations
defineWithPrimaryKeyDefault table keyType ixs = do
  instD <- defineHasPrimaryKeyInstanceDefault table keyType ixs
  let recType  = recordTypeDefault table
      tableE   = tableVarExpDefault table
      relE     = relationVarExpDefault table
  sqlsD <- defineSqlsWithPrimaryKeyDefault table keyType recType relE tableE
  return $ instD ++ sqlsD

-- | All templates about not-null key.
defineWithNotNullKeyDefault :: String -> Int -> Q [Dec]
defineWithNotNullKeyDefault =  defineHasNotNullKeyInstanceDefault

-- | Generate all templtes about table using default naming rule.
defineTableDefault :: String            -- ^ Schema name string of Database
                   -> String            -- ^ Table name string of Database
                   -> [(String, TypeQ)] -- ^ Column names and types
                   -> [ConName]         -- ^ derivings for Record type
                   -> [Int]             -- ^ Primary key index
                   -> Maybe Int         -- ^ Not null key index
                   -> Q [Dec]           -- ^ Result declarations
defineTableDefault schema table columns derives primaryIxs mayNotNullIdx = do
  tblD  <- defineTableDefault' schema table columns derives
  let pairT x y = appT (appT (tupleT 2) x) y
      keyType   = foldl1' pairT . map (snd . (columns !!)) $ primaryIxs
  primD <- case primaryIxs of
    []  -> return []
    ixs -> defineWithPrimaryKeyDefault table keyType ixs
  nnD   <- maybeD (\i -> defineWithNotNullKeyDefault table i) mayNotNullIdx
  return $ tblD ++ primD ++ nnD


-- | Inlining composed 'Query' in compile type.
inlineQuery :: VarName      -- ^ Top-level variable name which has 'Relation' type
            -> Relation p r -- ^ Object which has 'Relation' type
            -> VarName      -- ^ Variable name for inlined query
            -> Q [Dec]      -- ^ Result declarations
inlineQuery relVar' rel qVar' =  do
  let relVar = varName relVar'
      qVar   = varName qVar'
  relInfo <- reify relVar
  case relInfo of
    VarI _ (AppT (AppT (ConT prn) p) r) _ _
      | prn == ''Relation    -> do
        simpleValD qVar
          [t| Query $(return p) $(return r) |]
          [|  unsafeTypedQuery $(stringE . sqlFromRelation $ rel) |]
    _                             ->
      compileError $ "expandRelation: Variable must have Relation type: " ++ show relVar
