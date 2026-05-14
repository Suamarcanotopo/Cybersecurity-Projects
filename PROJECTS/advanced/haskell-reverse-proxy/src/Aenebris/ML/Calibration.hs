{-
©AngelaMos | 2026
Calibration.hs
-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}

module Aenebris.ML.Calibration
  ( Calibrator(..)
  , calibrate
  , fitPlatt
  , fitIsotonic
  ) where

import Data.List (sortBy)
import Data.Ord (comparing)
import qualified Data.Vector.Unboxed as VU
import GHC.Generics (Generic)

maxNewtonIterations :: Int
maxNewtonIterations = 100

newtonConvergenceTol :: Double
newtonConvergenceTol = 1.0e-7

initialPlattA :: Double
initialPlattA = 0.0

initialPlattB :: Double
initialPlattB = 0.0

minLineSearchStep :: Double
minLineSearchStep = 1.0e-10

initialLineSearchStep :: Double
initialLineSearchStep = 1.0

lineSearchShrinkFactor :: Double
lineSearchShrinkFactor = 0.5

degenerateHessianThreshold :: Double
degenerateHessianThreshold = 1.0e-12

degenerateFallbackStep :: Double
degenerateFallbackStep = 0.01

minSamplesForFitting :: Int
minSamplesForFitting = 2

singletonBlockWeight :: Double
singletonBlockWeight = 1.0

labelTrueValue :: Double
labelTrueValue = 1.0

labelFalseValue :: Double
labelFalseValue = 0.0

plattLabelSmoothingNumeratorOffset :: Double
plattLabelSmoothingNumeratorOffset = 1.0

plattLabelSmoothingDenominatorOffset :: Double
plattLabelSmoothingDenominatorOffset = 2.0

data Calibrator
  = NoCalibrator
  | PlattCalibrator !Double !Double
  | IsotonicCalibrator !(VU.Vector (Double, Double))
  deriving (Eq, Show, Generic)

calibrate :: Calibrator -> Double -> Double
calibrate NoCalibrator p              = p
calibrate (PlattCalibrator a b) p     = sigmoidPositiveExponent (a * p + b)
calibrate (IsotonicCalibrator bp) p   = isotonicLookup bp p

sigmoidPositiveExponent :: Double -> Double
sigmoidPositiveExponent z = 1.0 / (1.0 + exp z)

softplus :: Double -> Double
softplus z = max 0.0 z + log (1.0 + exp (negate (abs z)))

boolToTarget :: Bool -> Double
boolToTarget True  = labelTrueValue
boolToTarget False = labelFalseValue

fitPlatt :: VU.Vector (Double, Bool) -> Calibrator
fitPlatt samples
  | VU.length samples < minSamplesForFitting = NoCalibrator
  | otherwise =
      let !nPos      = VU.length (VU.filter snd samples)
          !nNeg      = VU.length samples - nPos
          !targetPos = (fromIntegral nPos + plattLabelSmoothingNumeratorOffset)
                       / (fromIntegral nPos + plattLabelSmoothingDenominatorOffset)
          !targetNeg = plattLabelSmoothingNumeratorOffset
                       / (fromIntegral nNeg + plattLabelSmoothingDenominatorOffset)
          smoothed   = VU.map
                         (\(p, lbl) -> (p, if lbl then targetPos else targetNeg))
                         samples
          (!a, !b)   = plattNewton smoothed
      in PlattCalibrator a b

plattNewton :: VU.Vector (Double, Double) -> (Double, Double)
plattNewton !smoothed = go 0 initialPlattA initialPlattB initialLoss
  where
    !initialLoss = computeNll smoothed initialPlattA initialPlattB

    go :: Int -> Double -> Double -> Double -> (Double, Double)
    go !iter !a !b !prevLoss
      | iter >= maxNewtonIterations = (a, b)
      | otherwise =
          let (!gA, !gB, !hAA, !hAB, !hBB) = gradHessian smoothed a b
              !det = hAA * hBB - hAB * hAB
              (!stepA, !stepB)
                | abs det < degenerateHessianThreshold =
                    ( negate gA * degenerateFallbackStep
                    , negate gB * degenerateFallbackStep
                    )
                | otherwise =
                    ( negate (hBB * gA - hAB * gB) / det
                    , negate (negate hAB * gA + hAA * gB) / det
                    )
              (!newA, !newB, !newLoss) =
                lineSearch smoothed a b stepA stepB prevLoss initialLineSearchStep
          in if abs (prevLoss - newLoss) < newtonConvergenceTol
               then (newA, newB)
               else go (iter + 1) newA newB newLoss

lineSearch
  :: VU.Vector (Double, Double)
  -> Double -> Double -> Double -> Double -> Double -> Double
  -> (Double, Double, Double)
lineSearch !smoothed !a !b !stepA !stepB !prevLoss !step
  | step < minLineSearchStep = (a, b, prevLoss)
  | otherwise =
      let !trialA    = a + step * stepA
          !trialB    = b + step * stepB
          !trialLoss = computeNll smoothed trialA trialB
      in if trialLoss < prevLoss
           then (trialA, trialB, trialLoss)
           else lineSearch smoothed a b stepA stepB prevLoss
                  (step * lineSearchShrinkFactor)

computeNll :: VU.Vector (Double, Double) -> Double -> Double -> Double
computeNll !smoothed !a !b = VU.foldl' addSample 0.0 smoothed
  where
    addSample !acc (!p, !t) =
      let !z = a * p + b
      in acc + softplus z - (1.0 - t) * z

gradHessian
  :: VU.Vector (Double, Double)
  -> Double
  -> Double
  -> (Double, Double, Double, Double, Double)
gradHessian !smoothed !a !b =
  VU.foldl' step (0.0, 0.0, 0.0, 0.0, 0.0) smoothed
  where
    step (!gA, !gB, !hAA, !hAB, !hBB) (!p, !t) =
      let !z   = a * p + b
          !q   = sigmoidPositiveExponent z
          !d   = t - q
          !dh  = q * (1.0 - q)
      in ( gA + d * p
         , gB + d
         , hAA + dh * p * p
         , hAB + dh * p
         , hBB + dh
         )

fitIsotonic :: VU.Vector (Double, Bool) -> Calibrator
fitIsotonic samples
  | VU.length samples < minSamplesForFitting = NoCalibrator
  | otherwise =
      let sorted      = sortBy (comparing fst) (VU.toList samples)
          grouped     = groupTies sorted
          smoothed    = pav grouped
          breakpoints = map blockToBreakpoint smoothed
      in IsotonicCalibrator (VU.fromList breakpoints)

groupTies :: [(Double, Bool)] -> [(Double, Double, Double)]
groupTies []                = []
groupTies ((r0, l0) : rest) = goGroup r0 singletonBlockWeight (boolToTarget l0) rest
  where
    goGroup !curR !w !sumL [] = [(curR * w, sumL, w)]
    goGroup !curR !w !sumL ((r, l) : rs)
      | r == curR = goGroup curR (w + singletonBlockWeight) (sumL + boolToTarget l) rs
      | otherwise = (curR * w, sumL, w)
                      : goGroup r singletonBlockWeight (boolToTarget l) rs

pav :: [(Double, Double, Double)] -> [(Double, Double, Double)]
pav xs = reverse (foldl' push [] xs)
  where
    push :: [(Double, Double, Double)]
         -> (Double, Double, Double)
         -> [(Double, Double, Double)]
    push []           b = [b]
    push (top : rest) b
      | blockMean top > blockMean b = push rest (mergeBlocks top b)
      | otherwise                    = b : top : rest

blockMean :: (Double, Double, Double) -> Double
blockMean (_, sumL, w) = sumL / w

blockRawMean :: (Double, Double, Double) -> Double
blockRawMean (sumR, _, w) = sumR / w

blockToBreakpoint :: (Double, Double, Double) -> (Double, Double)
blockToBreakpoint b = (blockRawMean b, blockMean b)

mergeBlocks
  :: (Double, Double, Double)
  -> (Double, Double, Double)
  -> (Double, Double, Double)
mergeBlocks (r1, l1, w1) (r2, l2, w2) = (r1 + r2, l1 + l2, w1 + w2)

isotonicLookup :: VU.Vector (Double, Double) -> Double -> Double
isotonicLookup !bp !p
  | VU.null bp                = p
  | p <= fst (VU.head bp)     = snd (VU.head bp)
  | p >= fst (VU.last bp)     = snd (VU.last bp)
  | otherwise                 = interpolateBp bp p

interpolateBp :: VU.Vector (Double, Double) -> Double -> Double
interpolateBp !bp !p =
  let !i              = bisectRight bp p
      (!loRaw, !loCal) = VU.unsafeIndex bp (i - 1)
      (!hiRaw, !hiCal) = VU.unsafeIndex bp i
      !range          = hiRaw - loRaw
  in if range == 0.0
       then loCal
       else
         let !frac = (p - loRaw) / range
         in loCal + frac * (hiCal - loCal)

bisectRight :: VU.Vector (Double, Double) -> Double -> Int
bisectRight !bp !p = go 0 (VU.length bp)
  where
    go !lo !hi
      | lo >= hi = lo
      | otherwise =
          let !mid              = lo + (hi - lo) `div` 2
              (!midRaw, _)      = VU.unsafeIndex bp mid
          in if midRaw > p
               then go lo mid
               else go (mid + 1) hi
