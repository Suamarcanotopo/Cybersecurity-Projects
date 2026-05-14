{-
©AngelaMos | 2026
Middleware.hs
-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

module Aenebris.ML.Middleware
  ( MLMiddlewareConfig(..)
  , defaultMLMiddlewareConfig
  , defaultBotResponse
  , defaultChallengeResponse
  , mlBotDetectionMiddleware
  , decisionResponseHeader
  , scoreResponseHeader
  , decisionToWireText
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as LBS
import Data.CaseInsensitive (CI)
import qualified Data.CaseInsensitive as CI
import Network.HTTP.Types (HeaderName, hContentType, status403)
import Network.Wai
  ( Application
  , Middleware
  , Request
  , Response
  , ResponseReceived
  , mapResponseHeaders
  , responseLBS
  )

import Aenebris.ML.Engine
  ( Decision(..)
  , DecisionDetails(..)
  , Engine
  , runEngine
  )
import Aenebris.ML.Features
  ( FeatureContext
  , extractFeatures
  , featureVectorToVector
  )

humanWireText :: ByteString
humanWireText = "human"

botWireText :: ByteString
botWireText = "bot"

challengeWireText :: ByteString
challengeWireText = "challenge"

botBlockBody :: LBS.ByteString
botBlockBody = "403 Forbidden - request blocked by Aenebris ML"

challengePageBody :: LBS.ByteString
challengePageBody =
  "<!DOCTYPE html>\n\
  \<html lang=\"en\">\n\
  \<head><meta charset=\"utf-8\"><title>Verification Required</title></head>\n\
  \<body>\n\
  \<h1>Verification Required</h1>\n\
  \<p>Aenebris ML flagged this request as ambiguous. Please complete a \
  \verification challenge to continue.</p>\n\
  \</body>\n\
  \</html>\n"

contentTypePlain :: ByteString
contentTypePlain = "text/plain; charset=utf-8"

contentTypeHtml :: ByteString
contentTypeHtml = "text/html; charset=utf-8"

decisionResponseHeader :: HeaderName
decisionResponseHeader = CI.mk "X-Aenebris-ML-Decision"

scoreResponseHeader :: HeaderName
scoreResponseHeader = CI.mk "X-Aenebris-ML-Score"

decisionToWireText :: Decision -> ByteString
decisionToWireText DecisionHuman     = humanWireText
decisionToWireText DecisionBot       = botWireText
decisionToWireText DecisionChallenge = challengeWireText

calibratedToHeaderValue :: Double -> ByteString
calibratedToHeaderValue = BC.pack . show

data MLMiddlewareConfig = MLMiddlewareConfig
  { mmcEngine            :: !Engine
  , mmcFeatureContext    :: !FeatureContext
  , mmcBotResponse       :: !(Request -> DecisionDetails -> Response)
  , mmcChallengeResponse :: !(Request -> DecisionDetails -> Response)
  , mmcLogDetails        :: !(Maybe (Request -> DecisionDetails -> IO ()))
  , mmcAttachHeaders     :: !Bool
  }

defaultMLMiddlewareConfig
  :: Engine
  -> FeatureContext
  -> MLMiddlewareConfig
defaultMLMiddlewareConfig eng ctx = MLMiddlewareConfig
  { mmcEngine            = eng
  , mmcFeatureContext    = ctx
  , mmcBotResponse       = defaultBotResponse
  , mmcChallengeResponse = defaultChallengeResponse
  , mmcLogDetails        = Nothing
  , mmcAttachHeaders     = True
  }

defaultBotResponse :: Request -> DecisionDetails -> Response
defaultBotResponse _req details =
  responseLBS
    status403
    (mlSignalHeaders DecisionBot details
      <> [(hContentType, contentTypePlain)])
    botBlockBody

defaultChallengeResponse :: Request -> DecisionDetails -> Response
defaultChallengeResponse _req details =
  responseLBS
    status403
    (mlSignalHeaders DecisionChallenge details
      <> [(hContentType, contentTypeHtml)])
    challengePageBody

mlSignalHeaders :: Decision -> DecisionDetails -> [(CI ByteString, ByteString)]
mlSignalHeaders decision details =
  [ (decisionResponseHeader, decisionToWireText decision)
  , (scoreResponseHeader,    calibratedToHeaderValue (ddCalibrated details))
  ]

mlBotDetectionMiddleware :: MLMiddlewareConfig -> Middleware
mlBotDetectionMiddleware cfg app req respond = do
  let !fv      = extractFeatures (mmcFeatureContext cfg) req
      !fvVec   = featureVectorToVector fv
      !details = runEngine (mmcEngine cfg) fvVec
  emitLog cfg req details
  routeDecision cfg app req respond details

emitLog
  :: MLMiddlewareConfig -> Request -> DecisionDetails -> IO ()
emitLog cfg req details = case mmcLogDetails cfg of
  Just logger -> logger req details
  Nothing     -> pure ()

routeDecision
  :: MLMiddlewareConfig
  -> Application
  -> Request
  -> (Response -> IO ResponseReceived)
  -> DecisionDetails
  -> IO ResponseReceived
routeDecision cfg app req respond details = case ddDecision details of
  DecisionHuman ->
    let respondWithHeaders =
          if mmcAttachHeaders cfg
            then respond . attachHumanSignalHeaders details
            else respond
    in app req respondWithHeaders
  DecisionBot ->
    respond (mmcBotResponse cfg req details)
  DecisionChallenge ->
    respond (mmcChallengeResponse cfg req details)

attachHumanSignalHeaders :: DecisionDetails -> Response -> Response
attachHumanSignalHeaders details =
  mapResponseHeaders (mlSignalHeaders DecisionHuman details ++)
