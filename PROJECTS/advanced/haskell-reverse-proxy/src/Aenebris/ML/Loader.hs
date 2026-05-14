{-
©AngelaMos | 2026
Loader.hs
-}
{-# LANGUAGE OverloadedStrings #-}

module Aenebris.ML.Loader
  ( ParseError(..)
  , parseEnsemble
  ) where

import Control.Monad (unless, when)
import Data.Bits (complement)
import qualified Data.ByteString as BS
import Data.Foldable (foldlM)
import Data.Int (Int8)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Read as TR
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as VU
import Data.Word (Word32)

import Aenebris.ML.Model
  ( Ensemble(..)
  , Objective(..)
  , Tree(..)
  , currentEnsembleVersion
  , defaultSigmoidScale
  , leafSentinel
  , makeLeafTree
  , noChildIndex
  , parseObjective
  , validateEnsemble
  )

expectedVersion :: Text
expectedVersion = "v4"

requiredNumClass :: Int
requiredNumClass = 1

requiredNumTreePerIteration :: Int
requiredNumTreePerIteration = 1

maxNumLeaves :: Int
maxNumLeaves = 4096

maxNumTrees :: Int
maxNumTrees = 10000

postParseLineSentinel :: Int
postParseLineSentinel = -1

initialBaseScore :: Double
initialBaseScore = 0.0

baseTreeKeyPrefix :: Text
baseTreeKeyPrefix = "Tree="

endOfTreesMarker :: Text
endOfTreesMarker = "end of trees"

averageOutputBareKey :: Text
averageOutputBareKey = "average_output"

sigmoidPrefix :: Text
sigmoidPrefix = "sigmoid:"

equalsSign :: Text
equalsSign = "="

validationKey :: Text
validationKey = "<validation>"

headerKey :: Text
headerKey = "<header>"

treeKey :: Text
treeKey = "<tree>"

keyTreeFirstLine :: Text
keyTreeFirstLine = "tree"

keyVersion :: Text
keyVersion = "version"

keyNumClass :: Text
keyNumClass = "num_class"

keyNumTreePerIteration :: Text
keyNumTreePerIteration = "num_tree_per_iteration"

keyLabelIndex :: Text
keyLabelIndex = "label_index"

keyMaxFeatureIdx :: Text
keyMaxFeatureIdx = "max_feature_idx"

keyObjective :: Text
keyObjective = "objective"

keyFeatureNames :: Text
keyFeatureNames = "feature_names"

keyFeatureInfos :: Text
keyFeatureInfos = "feature_infos"

keyMonotoneConstraints :: Text
keyMonotoneConstraints = "monotone_constraints"

keyTreeSizes :: Text
keyTreeSizes = "tree_sizes"

keyNumLeaves :: Text
keyNumLeaves = "num_leaves"

keyNumCat :: Text
keyNumCat = "num_cat"

keySplitFeature :: Text
keySplitFeature = "split_feature"

keyThreshold :: Text
keyThreshold = "threshold"

keyDecisionType :: Text
keyDecisionType = "decision_type"

keyLeftChild :: Text
keyLeftChild = "left_child"

keyRightChild :: Text
keyRightChild = "right_child"

keyLeafValue :: Text
keyLeafValue = "leaf_value"

keyCatBoundaries :: Text
keyCatBoundaries = "cat_boundaries"

keyCatThreshold :: Text
keyCatThreshold = "cat_threshold"

keyIsLinear :: Text
keyIsLinear = "is_linear"

ignoredHeaderKeys :: [Text]
ignoredHeaderKeys =
  [ keyFeatureInfos
  , keyLabelIndex
  , keyMonotoneConstraints
  , keyTreeSizes
  ]

ignoredTreeKeys :: [Text]
ignoredTreeKeys =
  [ "split_gain"
  , "leaf_weight"
  , "leaf_count"
  , "internal_value"
  , "internal_weight"
  , "internal_count"
  , "shrinkage"
  ]

data ParseError = ParseError
  { peLine   :: !Int
  , peKey    :: !Text
  , peReason :: !Text
  } deriving (Eq, Show)

data RawHeader = RawHeader
  { rhVersion             :: !Text
  , rhNumClass            :: !Int
  , rhNumTreePerIteration :: !Int
  , rhMaxFeatureIdx       :: !Int
  , rhFeatureCount        :: !Int
  , rhObjective           :: !Objective
  , rhSigmoidScale        :: !Double
  , rhAverageOutput       :: !Bool
  , rhFeatureNames        :: ![Text]
  }

data HeaderAcc = HeaderAcc
  { haVersion             :: !(Maybe Text)
  , haNumClass            :: !(Maybe Int)
  , haNumTreePerIteration :: !(Maybe Int)
  , haMaxFeatureIdx       :: !(Maybe Int)
  , haObjective           :: !(Maybe Objective)
  , haSigmoidScale        :: !Double
  , haAverageOutput       :: !Bool
  , haFeatureNames        :: !(Maybe [Text])
  }

emptyHeaderAcc :: HeaderAcc
emptyHeaderAcc = HeaderAcc
  { haVersion             = Nothing
  , haNumClass            = Nothing
  , haNumTreePerIteration = Nothing
  , haMaxFeatureIdx       = Nothing
  , haObjective           = Nothing
  , haSigmoidScale        = defaultSigmoidScale
  , haAverageOutput       = False
  , haFeatureNames        = Nothing
  }

data TreeAcc = TreeAcc
  { taNumLeaves     :: !(Maybe Int)
  , taNumCat        :: !(Maybe Int)
  , taSplitFeature  :: !(Maybe [Int])
  , taThreshold     :: !(Maybe [Double])
  , taDecisionType  :: !(Maybe [Int8])
  , taLeftChild     :: !(Maybe [Int])
  , taRightChild    :: !(Maybe [Int])
  , taLeafValue     :: !(Maybe [Double])
  , taCatBoundaries :: !(Maybe [Int])
  , taCatThreshold  :: !(Maybe [Word32])
  }

emptyTreeAcc :: TreeAcc
emptyTreeAcc = TreeAcc
  { taNumLeaves     = Nothing
  , taNumCat        = Nothing
  , taSplitFeature  = Nothing
  , taThreshold     = Nothing
  , taDecisionType  = Nothing
  , taLeftChild     = Nothing
  , taRightChild    = Nothing
  , taLeafValue     = Nothing
  , taCatBoundaries = Nothing
  , taCatThreshold  = Nothing
  }

parseEnsemble :: BS.ByteString -> Either ParseError Ensemble
parseEnsemble bs = case TE.decodeUtf8' bs of
  Left _   -> Left (ParseError 1 headerKey "Input is not valid UTF-8")
  Right tx -> parseFromText tx

parseFromText :: Text -> Either ParseError Ensemble
parseFromText tx = do
  let numbered = zip [1 :: Int ..] (T.lines tx)
  (hdr, afterHeader) <- runHeader numbered
  trees <- runTrees afterHeader
  let ens = buildEnsemble hdr trees
  case validateEnsemble (rhFeatureCount hdr) ens of
    Left err -> Left
      (ParseError postParseLineSentinel validationKey (T.pack err))
    Right () -> Right ens

buildEnsemble :: RawHeader -> [Tree] -> Ensemble
buildEnsemble hdr trees = Ensemble
  { ensembleVersion       = currentEnsembleVersion
  , ensembleFeatureCount  = rhFeatureCount hdr
  , ensembleObjective     = rhObjective hdr
  , ensembleBaseScore     = initialBaseScore
  , ensembleSigmoidScale  = rhSigmoidScale hdr
  , ensembleAverageOutput = rhAverageOutput hdr
  , ensembleTrees         = V.fromList trees
  }

runHeader :: [(Int, Text)] -> Either ParseError (RawHeader, [(Int, Text)])
runHeader allLines = case dropWhile (lineIsBlank . snd) allLines of
  [] -> Left (ParseError 1 headerKey "Empty input")
  ((n, firstLn):rest) -> do
    unless (T.strip firstLn == keyTreeFirstLine)
      (Left (ParseError n headerKey
              ("First non-empty line must be 'tree', got: " <> firstLn)))
    let (headerLines, treeRest) = breakAtTreeBlock rest
    acc <- foldlM absorbHeaderLine emptyHeaderAcc headerLines
    hdr <- finalizeHeader acc
    Right (hdr, treeRest)

breakAtTreeBlock :: [(Int, Text)] -> ([(Int, Text)], [(Int, Text)])
breakAtTreeBlock =
  break (\(_, t) -> T.isPrefixOf baseTreeKeyPrefix (T.strip t))

lineIsBlank :: Text -> Bool
lineIsBlank = T.null . T.strip

absorbHeaderLine :: HeaderAcc -> (Int, Text) -> Either ParseError HeaderAcc
absorbHeaderLine acc (n, rawLn) = do
  let stripped = T.strip rawLn
  if lineIsBlank stripped
    then Right acc
    else if stripped == averageOutputBareKey
      then Right acc { haAverageOutput = True }
      else do
        (key, val) <- splitKv n stripped
        assignHeaderField acc n key val

assignHeaderField
  :: HeaderAcc -> Int -> Text -> Text -> Either ParseError HeaderAcc
assignHeaderField acc n key val
  | key == keyVersion = do
      unless (val == expectedVersion)
        (Left (ParseError n keyVersion
                ("Unsupported version: " <> val)))
      Right acc { haVersion = Just val }
  | key == keyNumClass = do
      v <- parseDecimalInt n key val
      unless (v == requiredNumClass)
        (Left (ParseError n keyNumClass
                ("Multi-class not supported: num_class="
                 <> T.pack (show v))))
      Right acc { haNumClass = Just v }
  | key == keyNumTreePerIteration = do
      v <- parseDecimalInt n key val
      unless (v == requiredNumTreePerIteration)
        (Left (ParseError n keyNumTreePerIteration
                ("Multi-class not supported: num_tree_per_iteration="
                 <> T.pack (show v))))
      Right acc { haNumTreePerIteration = Just v }
  | key == keyMaxFeatureIdx = do
      v <- parseDecimalInt n key val
      Right acc { haMaxFeatureIdx = Just v }
  | key == keyObjective = do
      (obj, sig) <- parseObjectiveLine n val
      Right acc { haObjective = Just obj, haSigmoidScale = sig }
  | key == keyFeatureNames =
      Right acc { haFeatureNames = Just (T.words val) }
  | key `elem` ignoredHeaderKeys = Right acc
  | otherwise =
      Left (ParseError n key ("Unknown header key: " <> key))

finalizeHeader :: HeaderAcc -> Either ParseError RawHeader
finalizeHeader acc = do
  ver  <- requireField keyVersion (haVersion acc)
  nc   <- requireField keyNumClass (haNumClass acc)
  ntpi <- requireField keyNumTreePerIteration (haNumTreePerIteration acc)
  mfi  <- requireField keyMaxFeatureIdx (haMaxFeatureIdx acc)
  fns  <- requireField keyFeatureNames (haFeatureNames acc)
  let featureCount = mfi + 1
  unless (length fns == featureCount)
    (Left (ParseError postParseLineSentinel keyFeatureNames
            ("Feature name count "
             <> T.pack (show (length fns))
             <> " does not match max_feature_idx+1 "
             <> T.pack (show featureCount))))
  let obj = case haObjective acc of
              Just o  -> o
              Nothing -> ObjectiveBinaryLogistic
  Right RawHeader
    { rhVersion             = ver
    , rhNumClass            = nc
    , rhNumTreePerIteration = ntpi
    , rhMaxFeatureIdx       = mfi
    , rhFeatureCount        = featureCount
    , rhObjective           = obj
    , rhSigmoidScale        = haSigmoidScale acc
    , rhAverageOutput       = haAverageOutput acc
    , rhFeatureNames        = fns
    }

requireField :: Text -> Maybe a -> Either ParseError a
requireField key mv = case mv of
  Just v  -> Right v
  Nothing -> Left
    (ParseError postParseLineSentinel key
      ("Missing required header key: " <> key))

runTrees :: [(Int, Text)] -> Either ParseError [Tree]
runTrees = goTrees 0
  where
    goTrees :: Int -> [(Int, Text)] -> Either ParseError [Tree]
    goTrees treeCount lns
      | treeCount > maxNumTrees = Left
          (ParseError postParseLineSentinel treeKey
            ("Tree count exceeds maxNumTrees "
             <> T.pack (show maxNumTrees)))
      | otherwise = case dropWhile (lineIsBlank . snd) lns of
          [] -> Right []
          ((n, ln):rest)
            | T.strip ln == endOfTreesMarker -> Right []
            | T.isPrefixOf baseTreeKeyPrefix (T.strip ln) -> do
                let (block, after) = break (lineIsBlank . snd) rest
                tree <- parseTreeBlock block
                more <- goTrees (treeCount + 1) after
                Right (tree : more)
            | otherwise -> Left
                (ParseError n treeKey
                  ("Expected 'Tree=N' or 'end of trees', got: " <> ln))

parseTreeBlock :: [(Int, Text)] -> Either ParseError Tree
parseTreeBlock block = do
  acc <- foldlM absorbTreeLine emptyTreeAcc block
  finalizeTree acc

absorbTreeLine :: TreeAcc -> (Int, Text) -> Either ParseError TreeAcc
absorbTreeLine acc (n, rawLn) = do
  let stripped = T.strip rawLn
  if lineIsBlank stripped
    then Right acc
    else do
      (key, val) <- splitKv n stripped
      assignTreeField acc n key val

assignTreeField
  :: TreeAcc -> Int -> Text -> Text -> Either ParseError TreeAcc
assignTreeField acc n key val
  | key == keyNumLeaves = do
      v <- parseDecimalInt n key val
      Right acc { taNumLeaves = Just v }
  | key == keyNumCat = do
      v <- parseDecimalInt n key val
      Right acc { taNumCat = Just v }
  | key == keySplitFeature = do
      v <- parseIntArray n key val
      Right acc { taSplitFeature = Just v }
  | key == keyThreshold = do
      v <- parseDoubleArray n key val
      Right acc { taThreshold = Just v }
  | key == keyDecisionType = do
      v <- parseInt8Array n key val
      Right acc { taDecisionType = Just v }
  | key == keyLeftChild = do
      v <- parseIntArray n key val
      Right acc { taLeftChild = Just v }
  | key == keyRightChild = do
      v <- parseIntArray n key val
      Right acc { taRightChild = Just v }
  | key == keyLeafValue = do
      v <- parseDoubleArray n key val
      Right acc { taLeafValue = Just v }
  | key == keyCatBoundaries = do
      v <- parseIntArray n key val
      Right acc { taCatBoundaries = Just v }
  | key == keyCatThreshold = do
      v <- parseWord32Array n key val
      Right acc { taCatThreshold = Just v }
  | key == keyIsLinear = do
      v <- parseDecimalInt n key val
      when (v /= 0)
        (Left (ParseError n keyIsLinear
                "Linear trees not supported (is_linear=1)"))
      Right acc
  | key `elem` ignoredTreeKeys = Right acc
  | otherwise =
      Left (ParseError n key ("Unknown tree key: " <> key))

finalizeTree :: TreeAcc -> Either ParseError Tree
finalizeTree acc = do
  nL <- requireField keyNumLeaves (taNumLeaves acc)
  unless (nL > 0)
    (Left (ParseError postParseLineSentinel keyNumLeaves
            ("num_leaves must be positive: " <> T.pack (show nL))))
  unless (nL <= maxNumLeaves)
    (Left (ParseError postParseLineSentinel keyNumLeaves
            ("num_leaves " <> T.pack (show nL)
             <> " exceeds maxNumLeaves "
             <> T.pack (show maxNumLeaves))))
  nC <- requireField keyNumCat (taNumCat acc)
  leafValues <- requireField keyLeafValue (taLeafValue acc)
  unless (length leafValues == nL)
    (Left (ParseError postParseLineSentinel keyLeafValue
            ("leaf_value array length "
             <> T.pack (show (length leafValues))
             <> " does not match num_leaves "
             <> T.pack (show nL))))
  if nL == 1
    then buildStumpTree leafValues
    else buildSplitTree nL nC acc leafValues

buildStumpTree :: [Double] -> Either ParseError Tree
buildStumpTree [v] = Right (makeLeafTree v)
buildStumpTree _ = Left
  (ParseError postParseLineSentinel keyLeafValue
    "Stump tree must have exactly 1 leaf value")

buildSplitTree
  :: Int -> Int -> TreeAcc -> [Double] -> Either ParseError Tree
buildSplitTree nL nC acc leafValues = do
  let nI = nL - 1
  splitF <- requireField keySplitFeature (taSplitFeature acc)
  thr    <- requireField keyThreshold    (taThreshold acc)
  lefts  <- requireField keyLeftChild    (taLeftChild acc)
  rights <- requireField keyRightChild   (taRightChild acc)
  let dts = case taDecisionType acc of
              Just xs -> xs
              Nothing -> replicate nI 0
  validateArrayLen keySplitFeature  nI splitF
  validateArrayLen keyThreshold     nI thr
  validateArrayLen keyLeftChild     nI lefts
  validateArrayLen keyRightChild    nI rights
  validateArrayLen keyDecisionType  nI dts
  (catBounds, catThr) <- buildCategorical nC acc
  let internalLefts  = map (unifyChild nI) lefts
      internalRights = map (unifyChild nI) rights
      leafFeatures   = replicate nL leafSentinel
      leafThresholds = replicate nL 0.0
      leafDt         = replicate nL (0 :: Int8)
      leafLefts      = replicate nL noChildIndex
      leafRights     = replicate nL noChildIndex
      internalLv     = replicate nI 0.0
  Right Tree
    { treeFeatureIdx    = VU.fromList (splitF ++ leafFeatures)
    , treeThreshold     = VU.fromList (thr ++ leafThresholds)
    , treeLeftChild     = VU.fromList (internalLefts ++ leafLefts)
    , treeRightChild    = VU.fromList (internalRights ++ leafRights)
    , treeLeafValue     = VU.fromList (internalLv ++ leafValues)
    , treeDecisionType  = VU.fromList (dts ++ leafDt)
    , treeCatBoundaries = VU.fromList catBounds
    , treeCatThreshold  = VU.fromList catThr
    }

buildCategorical :: Int -> TreeAcc -> Either ParseError ([Int], [Word32])
buildCategorical nC acc
  | nC <= 0   = Right ([], [])
  | otherwise = do
      bounds <- requireField keyCatBoundaries (taCatBoundaries acc)
      thr    <- requireField keyCatThreshold  (taCatThreshold acc)
      Right (bounds, thr)

unifyChild :: Int -> Int -> Int
unifyChild nI n
  | n >= 0    = n
  | otherwise = nI + complement n

validateArrayLen :: Text -> Int -> [a] -> Either ParseError ()
validateArrayLen key expected xs
  | length xs == expected = Right ()
  | otherwise = Left
      (ParseError postParseLineSentinel key
        ("Array " <> key <> " has length "
         <> T.pack (show (length xs))
         <> ", expected " <> T.pack (show expected)))

splitKv :: Int -> Text -> Either ParseError (Text, Text)
splitKv n ln =
  let (k, rest) = T.breakOn equalsSign ln
  in if T.null rest
       then Left (ParseError n headerKey
                   ("Line missing '=': " <> ln))
       else Right (T.strip k, T.strip (T.drop 1 rest))

parseObjectiveLine :: Int -> Text -> Either ParseError (Objective, Double)
parseObjectiveLine n val = case T.words val of
  [] -> Left (ParseError n keyObjective "Empty objective value")
  (objName : rest) -> do
    obj <- case parseObjective objName of
      Left err -> Left (ParseError n keyObjective (T.pack err))
      Right o  -> Right o
    sig <- findSigmoid n rest
    Right (obj, sig)

findSigmoid :: Int -> [Text] -> Either ParseError Double
findSigmoid _ [] = Right defaultSigmoidScale
findSigmoid n (t:ts) = case T.stripPrefix sigmoidPrefix t of
  Nothing  -> findSigmoid n ts
  Just raw -> case TR.double raw of
    Right (d, leftover)
      | T.null leftover -> Right d
      | otherwise -> Left
          (ParseError n keyObjective
            ("Invalid sigmoid value: " <> raw))
    Left err -> Left
      (ParseError n keyObjective
        ("Invalid sigmoid value: " <> T.pack err))

parseDecimalInt :: Int -> Text -> Text -> Either ParseError Int
parseDecimalInt n key val =
  case TR.signed TR.decimal (T.strip val) of
    Right (v, leftover)
      | T.null leftover -> Right v
      | otherwise -> Left
          (ParseError n key
            ("Trailing characters after int: " <> leftover))
    Left err -> Left
      (ParseError n key ("Invalid integer: " <> T.pack err))

parseDouble :: Int -> Text -> Text -> Either ParseError Double
parseDouble n key val = case TR.double (T.strip val) of
  Right (v, leftover)
    | T.null leftover -> Right v
    | otherwise -> Left
        (ParseError n key
          ("Trailing characters after double: " <> leftover))
  Left err -> Left
    (ParseError n key ("Invalid double: " <> T.pack err))

parseIntArray :: Int -> Text -> Text -> Either ParseError [Int]
parseIntArray n key val = traverse (parseDecimalInt n key) (T.words val)

parseDoubleArray :: Int -> Text -> Text -> Either ParseError [Double]
parseDoubleArray n key val = traverse (parseDouble n key) (T.words val)

parseInt8Array :: Int -> Text -> Text -> Either ParseError [Int8]
parseInt8Array n key val = do
  ints <- parseIntArray n key val
  traverse (toInt8 n key) ints

toInt8 :: Int -> Text -> Int -> Either ParseError Int8
toInt8 n key v
  | v < fromIntegral (minBound :: Int8) =
      Left (ParseError n key
              ("Value below Int8 range: " <> T.pack (show v)))
  | v > fromIntegral (maxBound :: Int8) =
      Left (ParseError n key
              ("Value above Int8 range: " <> T.pack (show v)))
  | otherwise = Right (fromIntegral v)

parseWord32Array :: Int -> Text -> Text -> Either ParseError [Word32]
parseWord32Array n key val = traverse (parseWord32 n key) (T.words val)

parseWord32 :: Int -> Text -> Text -> Either ParseError Word32
parseWord32 n key val = case TR.decimal (T.strip val) of
  Right (v, leftover)
    | T.null leftover -> Right v
    | otherwise -> Left
        (ParseError n key
          ("Trailing characters after Word32: " <> leftover))
  Left err -> Left
    (ParseError n key ("Invalid Word32: " <> T.pack err))
