{-
©AngelaMos | 2026
Inference.hs
-}
{-# LANGUAGE BangPatterns #-}

module Aenebris.ML.Inference
  ( walkTree
  , predictRaw
  , predictScore
  , predictProba
  , sigmoidLink
  , kZeroThreshold
  ) where

import Data.Bits (shiftR, testBit, (.&.))
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as VU

import Aenebris.ML.Model
  ( Ensemble(..)
  , MissingType(..)
  , Objective(..)
  , SplitKind(..)
  , Tree(..)
  , decisionTypeBits
  , defaultRootIndex
  , ensembleTreeCount
  , nodeIsLeaf
  )

kZeroThreshold :: Double
kZeroThreshold = 1.0e-35

bitsPerWordShift :: Int
bitsPerWordShift = 5

bitsPerWordMask :: Int
bitsPerWordMask = 31

zeroFeatureValue :: Double
zeroFeatureValue = 0.0

sigmoidNumerator :: Double
sigmoidNumerator = 1.0

sigmoidBias :: Double
sigmoidBias = 1.0

walkTree :: Tree -> VU.Vector Double -> Int
walkTree !tree !fv = go defaultRootIndex
  where
    go !i
      | nodeIsLeaf tree i = i
      | otherwise         = go (chooseChild tree i fv)

chooseChild :: Tree -> Int -> VU.Vector Double -> Int
chooseChild !tree !i !fv =
  let !dt      = treeDecisionType tree VU.! i
      !featIdx = treeFeatureIdx tree VU.! i
      !rawFval = fv VU.! featIdx
      (!kind, !defaultLeft, !mtype) = decisionTypeBits dt
      !goLeft  = treeLeftChild  tree VU.! i
      !goRight = treeRightChild tree VU.! i
      !fval = if isNaN rawFval && mtype /= MissingTypeNaN
                then zeroFeatureValue
                else rawFval
  in if hitsMissingDefault mtype fval
       then if defaultLeft then goLeft else goRight
       else case kind of
              SplitNumerical
                | fval <= treeThreshold tree VU.! i -> goLeft
                | otherwise                          -> goRight
              SplitCategorical
                | categoricalGoesLeft tree i fval -> goLeft
                | otherwise                        -> goRight

hitsMissingDefault :: MissingType -> Double -> Bool
hitsMissingDefault MissingTypeZero fval = isZeroLgbm fval
hitsMissingDefault MissingTypeNaN  fval = isNaN fval
hitsMissingDefault MissingTypeNone _    = False

isZeroLgbm :: Double -> Bool
isZeroLgbm fval =
  fval > negate kZeroThreshold && fval < kZeroThreshold

categoricalGoesLeft :: Tree -> Int -> Double -> Bool
categoricalGoesLeft !tree !i !fval
  | isNaN fval || isInfinite fval || fval < 0 = False
  | otherwise =
      let !ifval  = floor fval :: Int
          !catIdx = floor (treeThreshold tree VU.! i) :: Int
          !bStart = treeCatBoundaries tree VU.! catIdx
          !bEnd   = treeCatBoundaries tree VU.! (catIdx + 1)
          !nWords = bEnd - bStart
          !off    = ifval `shiftR` bitsPerWordShift
      in (off < nWords)
         && testBit (treeCatThreshold tree VU.! (bStart + off))
                    (ifval .&. bitsPerWordMask)

predictRaw :: Ensemble -> VU.Vector Double -> Double
predictRaw !ens !fv = V.foldl' addLeafValue 0.0 (ensembleTrees ens)
  where
    addLeafValue !acc !tree =
      acc + treeLeafValue tree VU.! walkTree tree fv

predictScore :: Ensemble -> VU.Vector Double -> Double
predictScore !ens !fv =
  let !raw = predictRaw ens fv
      !n   = ensembleTreeCount ens
  in if ensembleAverageOutput ens && n > 0
       then raw / fromIntegral n
       else raw

predictProba :: Ensemble -> VU.Vector Double -> Double
predictProba !ens !fv =
  let !s = predictScore ens fv
  in case ensembleObjective ens of
       ObjectiveBinaryLogistic -> sigmoidLink (ensembleSigmoidScale ens) s
       ObjectiveRegression     -> s

sigmoidLink :: Double -> Double -> Double
sigmoidLink !scale !x =
  sigmoidNumerator / (sigmoidBias + exp (negate (scale * x)))
