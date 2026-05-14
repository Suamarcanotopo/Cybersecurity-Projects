{-
©AngelaMos | 2026
IForest.hs
-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}

module Aenebris.ML.IForest
  ( ITree(..)
  , IForest(..)
  , scoreIForest
  , pathLength
  , normalizationConstant
  , harmonicNumber
  , eulerMascheroni
  , minSubsampleForNormalization
  , defaultIForestNumTrees
  , defaultIForestSubsampleSize
  , maxIForestDepth
  ) where

import Data.Vector (Vector)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as VU
import GHC.Generics (Generic)

eulerMascheroni :: Double
eulerMascheroni = 0.5772156649015329

minSubsampleForNormalization :: Int
minSubsampleForNormalization = 2

initialDepth :: Int
initialDepth = 0

zeroAnomalyScore :: Double
zeroAnomalyScore = 0.0

scoreBase :: Double
scoreBase = 2.0

defaultIForestNumTrees :: Int
defaultIForestNumTrees = 100

defaultIForestSubsampleSize :: Int
defaultIForestSubsampleSize = 256

maxIForestDepth :: Int
maxIForestDepth = 64

depthBoundLeafSize :: Int
depthBoundLeafSize = 1

data ITree
  = ITreeLeaf !Int
  | ITreeSplit !Int !Double !ITree !ITree
  deriving (Eq, Show, Generic)

data IForest = IForest
  { ifTrees         :: !(Vector ITree)
  , ifSubsampleSize :: !Int
  } deriving (Eq, Show, Generic)

scoreIForest :: IForest -> VU.Vector Double -> Double
scoreIForest !forest !fv =
  let !trees     = ifTrees forest
      !numTrees  = V.length trees
      !subsample = ifSubsampleSize forest
      !cn        = normalizationConstant subsample
  in if numTrees == 0 || cn <= 0.0
       then zeroAnomalyScore
       else
         let !eHx = averagePathLength trees fv
         in scoreBase ** (negate eHx / cn)

averagePathLength :: Vector ITree -> VU.Vector Double -> Double
averagePathLength !trees !fv =
  let !numTrees   = V.length trees
      !totalDepth = V.foldl' addPath 0.0 trees
  in if numTrees == 0
       then 0.0
       else totalDepth / fromIntegral numTrees
  where
    addPath !acc !tree = acc + pathLength tree fv initialDepth

pathLength :: ITree -> VU.Vector Double -> Int -> Double
pathLength !tree !fv !currentDepth
  | currentDepth >= maxIForestDepth =
      fromIntegral currentDepth + normalizationConstant depthBoundLeafSize
  | otherwise = case tree of
      ITreeLeaf !size ->
        fromIntegral currentDepth + normalizationConstant size
      ITreeSplit !featIdx !thr !left !right ->
        let !fval = fv VU.! featIdx
        in if fval <= thr
             then pathLength left  fv (currentDepth + 1)
             else pathLength right fv (currentDepth + 1)

normalizationConstant :: Int -> Double
normalizationConstant n
  | n < minSubsampleForNormalization = 0.0
  | otherwise =
      let !nDouble    = fromIntegral n
          !nMinusOne  = fromIntegral (n - 1)
      in 2.0 * harmonicNumber (n - 1) - 2.0 * nMinusOne / nDouble

harmonicNumber :: Int -> Double
harmonicNumber n
  | n <= 0    = 0.0
  | otherwise = go 1 0.0
  where
    go :: Int -> Double -> Double
    go !i !acc
      | i > n     = acc
      | otherwise = go (i + 1) (acc + 1.0 / fromIntegral i)
