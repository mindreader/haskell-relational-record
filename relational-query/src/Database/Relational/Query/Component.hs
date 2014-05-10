{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}

-- |
-- Module      : Database.Relational.Query.Component
-- Copyright   : 2013 Kei Hibino
-- License     : BSD3
--
-- Maintainer  : ex8k.hibino@gmail.com
-- Stability   : experimental
-- Portability : unknown
--
-- This module provides untyped components for query.
module Database.Relational.Query.Component (
  -- * Type for column SQL string
  ColumnSQL, columnSQL, sqlWordFromColumn, showsColumnSQL,

  -- * Configuration type for query
  Config, defaultConfig,
  UnitProductSupport (..), Duplication (..),

  -- * Duplication attribute
  showsDuplication,

  -- * Query restriction
  QueryRestriction, composeWhere, composeHaving,

  -- * Types for aggregation
  AggregateColumnRef,

  AggregateBitKey, AggregateSet, AggregateElem,

  aggregateColumnRef, aggregateEmpty,
  aggregatePowerKey, aggregateGroupingSet,
  aggregateRollup, aggregateCube, aggregateSets,

  composeGroupBy, composePartitionBy,

  -- * Types for ordering
  Order (..), OrderColumn, OrderingTerm, OrderingTerms,
  composeOrderBy,

  -- * Types for assignments
  AssignColumn, AssignTerm, Assignment, Assignments, composeSets,

  -- * Compose window clause
  composeOver
) where

import Data.Functor.Identity (Identity (..))

import qualified Database.Relational.Query.Context as Context
import Database.Relational.Query.Expr (Expr)
import Database.Relational.Query.Expr.Unsafe (showExpr)

import Database.Relational.Query.Internal.String
  (showUnwordsSQL, showWordSQL, showWordSQL', showSpace, showParen', showSepBy)
import Database.Relational.Query.Internal.SQL (StringSQL)
import Language.SQL.Keyword (Keyword(..))

import qualified Language.SQL.Keyword as SQL

-- | Column SQL string type
type ColumnSQL = Identity String

-- | 'ColumnSQL' from string
columnSQL :: String -> ColumnSQL
columnSQL =  Identity

-- | String from ColumnSQL
stringFromColumnSQL :: ColumnSQL -> String
stringFromColumnSQL =  runIdentity

-- | SQL word from 'ColumnSQL'
sqlWordFromColumn :: ColumnSQL -> SQL.Keyword
sqlWordFromColumn =  SQL.word . stringFromColumnSQL

-- | StringSQL from ColumnSQL
showsColumnSQL :: ColumnSQL -> StringSQL
showsColumnSQL =  showString . stringFromColumnSQL

instance Show ColumnSQL where
  show = stringFromColumnSQL


-- | Configuration type.
type Config = UnitProductSupport

-- | Default configuration.
defaultConfig :: Config
defaultConfig =  UPSupported

-- | Unit product is supported or not.
data UnitProductSupport = UPSupported | UPNotSupported  deriving Show


-- | Result record duplication attribute
data Duplication = All | Distinct  deriving Show

-- | Compose duplication attribute string.
showsDuplication :: Duplication -> StringSQL
showsDuplication =  showWordSQL . dup  where
  dup All      = ALL
  dup Distinct = DISTINCT


-- | Type for restriction of query.
type QueryRestriction c = Maybe (Expr c Bool)

-- | Compose SQL String from 'QueryRestriction'.
composeRestrict :: Keyword -> QueryRestriction c -> StringSQL
composeRestrict k = maybe id (\e -> showSpace . showUnwordsSQL [k, SQL.word . showExpr $ e])

-- | Compose WHERE clause from 'QueryRestriction'.
composeWhere :: QueryRestriction Context.Flat -> StringSQL
composeWhere =  composeRestrict WHERE

-- | Compose HAVING clause from 'QueryRestriction'.
composeHaving :: QueryRestriction Context.Aggregated -> StringSQL
composeHaving =  composeRestrict HAVING


-- | Type for group-by term
type AggregateColumnRef = ColumnSQL

-- | Type for group key.
newtype AggregateBitKey = AggregateBitKey [AggregateColumnRef] deriving Show

-- | Type for grouping set
newtype AggregateSet = AggregateSet [AggregateElem] deriving Show

-- | Type for group-by tree
data AggregateElem = ColumnRef AggregateColumnRef
                   | Rollup [AggregateBitKey]
                   | Cube   [AggregateBitKey]
                   | GroupingSets [AggregateSet]
                   deriving Show

-- | Single term aggregation element.
aggregateColumnRef :: AggregateColumnRef -> AggregateElem
aggregateColumnRef =  ColumnRef

-- | Key of aggregation power set.
aggregatePowerKey :: [AggregateColumnRef] -> AggregateBitKey
aggregatePowerKey =  AggregateBitKey

-- | Single grouping set.
aggregateGroupingSet :: [AggregateElem] -> AggregateSet
aggregateGroupingSet =  AggregateSet

-- | Rollup aggregation element.
aggregateRollup :: [AggregateBitKey] -> AggregateElem
aggregateRollup =  Rollup

-- | Cube aggregation element.
aggregateCube :: [AggregateBitKey] -> AggregateElem
aggregateCube =  Cube

-- | Grouping sets aggregation.
aggregateSets :: [AggregateSet] -> AggregateElem
aggregateSets =  GroupingSets

-- | Empty aggregation.
aggregateEmpty :: [AggregateElem]
aggregateEmpty =  []

comma :: StringSQL
comma =  showString ", "

showsAggregateColumnRef :: AggregateColumnRef -> StringSQL
showsAggregateColumnRef =  showsColumnSQL

parenSepByComma :: (a -> StringSQL) -> [a] -> StringSQL
parenSepByComma shows' = showParen' . (`showSepBy` comma) . map shows'

showsAggregateBitKey :: AggregateBitKey -> StringSQL
showsAggregateBitKey (AggregateBitKey ts) = parenSepByComma showsAggregateColumnRef ts

-- | Compose GROUP BY clause from AggregateElem list.
composeGroupBy :: [AggregateElem] -> StringSQL
composeGroupBy =  d where
  d []       = id
  d es@(_:_) = showSpace . showUnwordsSQL [GROUP, BY] . showSpace . rec es
  keyList op ss = showWordSQL' op . parenSepByComma showsAggregateBitKey ss
  rec = (`showSepBy` comma) . map showsE
  showsGs (AggregateSet s) = showParen' $ rec s
  showsE (ColumnRef t)     = showsAggregateColumnRef t
  showsE (Rollup ss)       = keyList ROLLUP ss
  showsE (Cube   ss)       = keyList CUBE   ss
  showsE (GroupingSets ss) = showUnwordsSQL [GROUPING, SETS] . showSpace
                             . parenSepByComma showsGs ss

-- | Compose PARTITION BY clause from AggregateColumnRef list.
composePartitionBy :: [AggregateColumnRef] -> StringSQL
composePartitionBy =  d where
  d []       = id
  d ts@(_:_) = showUnwordsSQL [PARTITION, BY] . showSpace
               . (map showsAggregateColumnRef ts `showSepBy` comma)

-- | Order direction. Ascendant or Descendant.
data Order = Asc | Desc  deriving Show

-- | Type for order-by column
type OrderColumn = ColumnSQL

-- | Type for order-by term
type OrderingTerm = (Order, OrderColumn)

-- | Type for order-by terms
type OrderingTerms = [OrderingTerm]

-- | Compose ORDER BY clause from OrderingTerms
composeOrderBy :: OrderingTerms -> StringSQL
composeOrderBy =  d where
  d []       = id
  d ts@(_:_) = showSpace . showUnwordsSQL [ORDER, BY] . showSpace
               . (map showsOt ts `showSepBy` comma)
  showsOt (o, e) = showsColumnSQL e . showSpace . showWordSQL (order o)
  order Asc  = ASC
  order Desc = DESC


-- | Column SQL String
type AssignColumn = ColumnSQL

-- | Value SQL String
type AssignTerm   = ColumnSQL

-- | Assignment pair
type Assignment = (AssignColumn, AssignTerm)

-- | Assignment pair list.
type Assignments = [Assignment]

-- | Compose SET clause from 'Assignments'.
composeSets :: Assignments -> StringSQL
composeSets as = assigns  where
  assignList = foldr (\ (col, term) r ->
                       [sqlWordFromColumn col, sqlWordFromColumn term] `SQL.sepBy` " = "  : r)
               [] as
  assigns | null assignList = error "Update assignment list is null!"
          | otherwise       = showSpace . showUnwordsSQL [SET, assignList `SQL.sepBy` ", "]


-- | Compose /OVER (PARTITION BY ... )/ clause.
composeOver :: [AggregateColumnRef] -> OrderingTerms -> StringSQL
composeOver pts ots =
  showSpace . showWordSQL' OVER . showParen' (composePartitionBy pts . composeOrderBy ots)
