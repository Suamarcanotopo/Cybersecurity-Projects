{-
©AngelaMos | 2026
Model.hs
-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Aenebris.ML.Model
  ( Tree(..)
  , Ensemble(..)
  , Objective(..)
  , MissingType(..)
  , SplitKind(..)
  , decisionTypeBits
  , missingTypeFromDecisionType
  , defaultLeftFromDecisionType
  , splitKindFromDecisionType
  , makeDecisionType
  , kCategoricalMask
  , kDefaultLeftMask
  , kMissingTypeShift
  , kMissingTypeMask
  , leafSentinel
  , noChildIndex
  , defaultRootIndex
  , currentEnsembleVersion
  , minimumEnsembleVersion
  , maximumEnsembleVersion
  , defaultSigmoidScale
  , makeLeafTree
  , makeStumpTree
  , makeStumpTreeWithMissing
  , makeCategoricalStumpTree
  , treeNodeCount
  , ensembleTreeCount
  , nodeIsLeaf
  , validateTree
  , validateEnsemble
  , parseObjective
  , renderObjective
  ) where

import Data.Bits ((.&.), (.|.), shiftR, shiftL)
import Data.Int (Int8)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Vector (Vector)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as VU
import Data.Word (Word32)
import GHC.Generics (Generic)

leafSentinel :: Int
leafSentinel = -1

noChildIndex :: Int
noChildIndex = -1

defaultRootIndex :: Int
defaultRootIndex = 0

currentEnsembleVersion :: Int
currentEnsembleVersion = 1

minimumEnsembleVersion :: Int
minimumEnsembleVersion = 1

maximumEnsembleVersion :: Int
maximumEnsembleVersion = 1

defaultSigmoidScale :: Double
defaultSigmoidScale = 1.0

kCategoricalMask :: Int8
kCategoricalMask = 1

kDefaultLeftMask :: Int8
kDefaultLeftMask = 2

kMissingTypeShift :: Int
kMissingTypeShift = 2

kMissingTypeMask :: Int8
kMissingTypeMask = 12

data Objective
  = ObjectiveBinaryLogistic
  | ObjectiveRegression
  deriving (Eq, Show, Generic)

parseObjective :: Text -> Either String Objective
parseObjective t = case T.toLower t of
  "binary"          -> Right ObjectiveBinaryLogistic
  "binary_logistic" -> Right ObjectiveBinaryLogistic
  "logistic"        -> Right ObjectiveBinaryLogistic
  "regression"      -> Right ObjectiveRegression
  "regression_l2"   -> Right ObjectiveRegression
  other             -> Left ("Unknown objective: " <> T.unpack other)

renderObjective :: Objective -> Text
renderObjective ObjectiveBinaryLogistic = "binary_logistic"
renderObjective ObjectiveRegression     = "regression"

data MissingType
  = MissingTypeNone
  | MissingTypeZero
  | MissingTypeNaN
  deriving (Eq, Show, Generic)

data SplitKind
  = SplitNumerical
  | SplitCategorical
  deriving (Eq, Show, Generic)

decisionTypeBits :: Int8 -> (SplitKind, Bool, MissingType)
decisionTypeBits dt =
  ( splitKindFromDecisionType dt
  , defaultLeftFromDecisionType dt
  , missingTypeFromDecisionType dt
  )

splitKindFromDecisionType :: Int8 -> SplitKind
splitKindFromDecisionType dt
  | dt .&. kCategoricalMask /= 0 = SplitCategorical
  | otherwise                    = SplitNumerical

defaultLeftFromDecisionType :: Int8 -> Bool
defaultLeftFromDecisionType dt = dt .&. kDefaultLeftMask /= 0

missingTypeFromDecisionType :: Int8 -> MissingType
missingTypeFromDecisionType dt =
  case (dt .&. kMissingTypeMask) `shiftR` kMissingTypeShift of
    0 -> MissingTypeNone
    1 -> MissingTypeZero
    2 -> MissingTypeNaN
    _ -> MissingTypeNone

makeDecisionType :: SplitKind -> Bool -> MissingType -> Int8
makeDecisionType kind defaultLeft mtype =
  let kBit = case kind of
        SplitNumerical   -> 0
        SplitCategorical -> kCategoricalMask
      dBit = if defaultLeft then kDefaultLeftMask else 0
      mBits = case mtype of
        MissingTypeNone -> 0
        MissingTypeZero -> 1 `shiftL` kMissingTypeShift
        MissingTypeNaN  -> 2 `shiftL` kMissingTypeShift
  in kBit .|. dBit .|. mBits

data Tree = Tree
  { treeFeatureIdx    :: !(VU.Vector Int)
  , treeThreshold     :: !(VU.Vector Double)
  , treeLeftChild     :: !(VU.Vector Int)
  , treeRightChild    :: !(VU.Vector Int)
  , treeLeafValue     :: !(VU.Vector Double)
  , treeDecisionType  :: !(VU.Vector Int8)
  , treeCatBoundaries :: !(VU.Vector Int)
  , treeCatThreshold  :: !(VU.Vector Word32)
  } deriving (Eq, Show)

data Ensemble = Ensemble
  { ensembleVersion       :: !Int
  , ensembleFeatureCount  :: !Int
  , ensembleObjective     :: !Objective
  , ensembleBaseScore     :: !Double
  , ensembleSigmoidScale  :: !Double
  , ensembleAverageOutput :: !Bool
  , ensembleTrees         :: !(Vector Tree)
  } deriving (Eq, Show)

treeNodeCount :: Tree -> Int
treeNodeCount = VU.length . treeFeatureIdx

ensembleTreeCount :: Ensemble -> Int
ensembleTreeCount = V.length . ensembleTrees

nodeIsLeaf :: Tree -> Int -> Bool
nodeIsLeaf t i = treeFeatureIdx t VU.! i == leafSentinel

makeLeafTree :: Double -> Tree
makeLeafTree v = Tree
  { treeFeatureIdx    = VU.singleton leafSentinel
  , treeThreshold     = VU.singleton 0.0
  , treeLeftChild     = VU.singleton noChildIndex
  , treeRightChild    = VU.singleton noChildIndex
  , treeLeafValue     = VU.singleton v
  , treeDecisionType  = VU.singleton 0
  , treeCatBoundaries = VU.empty
  , treeCatThreshold  = VU.empty
  }

makeStumpTree :: Int -> Double -> Double -> Double -> Tree
makeStumpTree featureIdx threshold leftValue rightValue =
  makeStumpTreeWithMissing featureIdx threshold leftValue rightValue
    True MissingTypeNone

makeStumpTreeWithMissing
  :: Int
  -> Double
  -> Double
  -> Double
  -> Bool
  -> MissingType
  -> Tree
makeStumpTreeWithMissing featureIdx threshold leftValue rightValue defaultLeft mtype =
  Tree
    { treeFeatureIdx    = VU.fromList [featureIdx, leafSentinel, leafSentinel]
    , treeThreshold     = VU.fromList [threshold, 0.0, 0.0]
    , treeLeftChild     = VU.fromList [1, noChildIndex, noChildIndex]
    , treeRightChild    = VU.fromList [2, noChildIndex, noChildIndex]
    , treeLeafValue     = VU.fromList [0.0, leftValue, rightValue]
    , treeDecisionType  = VU.fromList
        [ makeDecisionType SplitNumerical defaultLeft mtype
        , 0
        , 0
        ]
    , treeCatBoundaries = VU.empty
    , treeCatThreshold  = VU.empty
    }

makeCategoricalStumpTree
  :: Int
  -> [Word32]
  -> Double
  -> Double
  -> Tree
makeCategoricalStumpTree featureIdx bitmap leftValue rightValue =
  let bitmapVec = VU.fromList bitmap
      boundaries = VU.fromList [0, VU.length bitmapVec]
  in Tree
       { treeFeatureIdx    = VU.fromList [featureIdx, leafSentinel, leafSentinel]
       , treeThreshold     = VU.fromList [0.0, 0.0, 0.0]
       , treeLeftChild     = VU.fromList [1, noChildIndex, noChildIndex]
       , treeRightChild    = VU.fromList [2, noChildIndex, noChildIndex]
       , treeLeafValue     = VU.fromList [0.0, leftValue, rightValue]
       , treeDecisionType  = VU.fromList
           [ makeDecisionType SplitCategorical False MissingTypeNone
           , 0
           , 0
           ]
       , treeCatBoundaries = boundaries
       , treeCatThreshold  = bitmapVec
       }

validateTree :: Int -> Tree -> Either String ()
validateTree featureCount t = do
  let nFeat  = VU.length (treeFeatureIdx t)
      nThr   = VU.length (treeThreshold t)
      nLeft  = VU.length (treeLeftChild t)
      nRight = VU.length (treeRightChild t)
      nLeaf  = VU.length (treeLeafValue t)
      nDec   = VU.length (treeDecisionType t)
  if nFeat == 0
    then Left "Tree must contain at least one node"
    else Right ()
  if nThr == nFeat
     && nLeft == nFeat
     && nRight == nFeat
     && nLeaf == nFeat
     && nDec == nFeat
    then Right ()
    else Left "Tree SoA arrays have inconsistent lengths"
  validateCategoricalArrays t
  let nodeCount = nFeat
      indices   = [0 .. nodeCount - 1]
  mapM_ (validateNode featureCount nodeCount t) indices

validateCategoricalArrays :: Tree -> Either String ()
validateCategoricalArrays t =
  let nBoundaries = VU.length (treeCatBoundaries t)
      nThresholds = VU.length (treeCatThreshold t)
  in if nBoundaries == 0 && nThresholds == 0
       then Right ()
       else if nBoundaries < 2
         then Left "Categorical boundaries must have length >= 2 if present"
         else
           let lastBoundary = treeCatBoundaries t VU.! (nBoundaries - 1)
           in if lastBoundary == nThresholds
                then Right ()
                else Left
                  $ "Categorical bitmap length "
                  <> show nThresholds
                  <> " does not match last boundary "
                  <> show lastBoundary

validateNode :: Int -> Int -> Tree -> Int -> Either String ()
validateNode featureCount nodeCount t i =
  let !fIdx = treeFeatureIdx t VU.! i
      !lIdx = treeLeftChild t VU.! i
      !rIdx = treeRightChild t VU.! i
      !dt   = treeDecisionType t VU.! i
      kind  = splitKindFromDecisionType dt
  in if fIdx == leafSentinel
       then validateLeafNode i lIdx rIdx
       else case kind of
         SplitNumerical -> validateSplitNode featureCount nodeCount i fIdx lIdx rIdx
         SplitCategorical ->
           validateCategoricalNode featureCount nodeCount t i fIdx lIdx rIdx

validateLeafNode :: Int -> Int -> Int -> Either String ()
validateLeafNode i lIdx rIdx
  | lIdx /= noChildIndex =
      Left ("Leaf node " <> show i <> " must have left child = -1")
  | rIdx /= noChildIndex =
      Left ("Leaf node " <> show i <> " must have right child = -1")
  | otherwise = Right ()

validateSplitNode :: Int -> Int -> Int -> Int -> Int -> Int -> Either String ()
validateSplitNode featureCount nodeCount i fIdx lIdx rIdx
  | fIdx < 0 || fIdx >= featureCount =
      Left ("Split node " <> show i
            <> " has out-of-range feature index " <> show fIdx)
  | lIdx < 0 || lIdx >= nodeCount =
      Left ("Split node " <> show i
            <> " has out-of-range left child " <> show lIdx)
  | rIdx < 0 || rIdx >= nodeCount =
      Left ("Split node " <> show i
            <> " has out-of-range right child " <> show rIdx)
  | lIdx == i =
      Left ("Split node " <> show i <> " has self-referential left child")
  | rIdx == i =
      Left ("Split node " <> show i <> " has self-referential right child")
  | lIdx == rIdx =
      Left ("Split node " <> show i <> " has identical left and right children")
  | otherwise = Right ()

validateCategoricalNode
  :: Int -> Int -> Tree -> Int -> Int -> Int -> Int -> Either String ()
validateCategoricalNode featureCount nodeCount t i fIdx lIdx rIdx = do
  validateSplitNode featureCount nodeCount i fIdx lIdx rIdx
  let rawThreshold = treeThreshold t VU.! i
      catIdx       = floor rawThreshold :: Int
      nBound       = VU.length (treeCatBoundaries t)
  if fromIntegral catIdx /= rawThreshold
    then Left ("Categorical node " <> show i
               <> " has non-integer threshold " <> show rawThreshold)
    else if nBound < 2
      then Left ("Categorical node " <> show i
                 <> " requires non-empty cat_boundaries")
      else if catIdx < 0 || catIdx >= nBound - 1
        then Left ("Categorical node " <> show i
                   <> " has out-of-range bitmap slice index " <> show catIdx)
        else Right ()

validateEnsemble :: Int -> Ensemble -> Either String ()
validateEnsemble expectedFeatures ens = do
  let v = ensembleVersion ens
  if v < minimumEnsembleVersion || v > maximumEnsembleVersion
    then Left ("Unsupported ensemble version: " <> show v)
    else Right ()
  if ensembleFeatureCount ens /= expectedFeatures
    then Left ("Ensemble feature count " <> show (ensembleFeatureCount ens)
               <> " does not match expected " <> show expectedFeatures)
    else Right ()
  if V.null (ensembleTrees ens)
    then Left "Ensemble must contain at least one tree"
    else Right ()
  V.imapM_
    (\i tree -> case validateTree (ensembleFeatureCount ens) tree of
        Right () -> Right ()
        Left err -> Left ("Tree " <> show i <> ": " <> err))
    (ensembleTrees ens)
