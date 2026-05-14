{-
©AngelaMos | 2026
Engine.hs
-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}

module Aenebris.ML.Engine
  ( Engine(..)
  , EngineConfig(..)
  , Decision(..)
  , DecisionDetails(..)
  , defaultEngineConfig
  , makeEngine
  , runEngine
  , runEngineDecision
  ) where

import qualified Data.Vector.Unboxed as VU
import GHC.Generics (Generic)

import Aenebris.ML.Calibration
  ( Calibrator(..)
  , calibrate
  )
import Aenebris.ML.IForest
  ( IForest
  , scoreIForest
  )
import Aenebris.ML.Inference
  ( predictProba
  )
import Aenebris.ML.Model
  ( Ensemble
  )

defaultHumanThreshold :: Double
defaultHumanThreshold = 0.3

defaultBotThreshold :: Double
defaultBotThreshold = 0.7

defaultIForestEscalation :: Double
defaultIForestEscalation = 0.6

defaultChallengeOnAmbiguous :: Bool
defaultChallengeOnAmbiguous = True

data Decision
  = DecisionHuman
  | DecisionBot
  | DecisionChallenge
  deriving (Eq, Show, Generic)

data EngineConfig = EngineConfig
  { ecHumanThreshold       :: !Double
  , ecBotThreshold         :: !Double
  , ecIForestEscalation    :: !Double
  , ecChallengeOnAmbiguous :: !Bool
  } deriving (Eq, Show, Generic)

defaultEngineConfig :: EngineConfig
defaultEngineConfig = EngineConfig
  { ecHumanThreshold       = defaultHumanThreshold
  , ecBotThreshold         = defaultBotThreshold
  , ecIForestEscalation    = defaultIForestEscalation
  , ecChallengeOnAmbiguous = defaultChallengeOnAmbiguous
  }

data Engine = Engine
  { engineEnsemble   :: !Ensemble
  , engineCalibrator :: !Calibrator
  , engineIForest    :: !(Maybe IForest)
  , engineConfig     :: !EngineConfig
  }

data DecisionDetails = DecisionDetails
  { ddDecision     :: !Decision
  , ddRawProba     :: !Double
  , ddCalibrated   :: !Double
  , ddIForestScore :: !(Maybe Double)
  } deriving (Eq, Show, Generic)

makeEngine
  :: Ensemble
  -> Calibrator
  -> Maybe IForest
  -> EngineConfig
  -> Engine
makeEngine = Engine

runEngine :: Engine -> VU.Vector Double -> DecisionDetails
runEngine !eng !fv =
  let !raw        = predictProba (engineEnsemble eng) fv
      !calibrated = calibrate (engineCalibrator eng) raw
      !mIfScore   = fmap (\f -> scoreIForest f fv) (engineIForest eng)
      !decision   = decideOutcome (engineConfig eng) calibrated mIfScore
  in DecisionDetails
       { ddDecision     = decision
       , ddRawProba     = raw
       , ddCalibrated   = calibrated
       , ddIForestScore = mIfScore
       }

runEngineDecision :: Engine -> VU.Vector Double -> Decision
runEngineDecision eng fv = ddDecision (runEngine eng fv)

decideOutcome :: EngineConfig -> Double -> Maybe Double -> Decision
decideOutcome !cfg !calibrated !mIfScore
  | calibrated <= ecHumanThreshold cfg = DecisionHuman
  | calibrated >= ecBotThreshold cfg   = DecisionBot
  | otherwise =
      case mIfScore of
        Just ifScore | ifScore >= ecIForestEscalation cfg ->
          DecisionBot
        _ ->
          if ecChallengeOnAmbiguous cfg
            then DecisionChallenge
            else DecisionHuman
