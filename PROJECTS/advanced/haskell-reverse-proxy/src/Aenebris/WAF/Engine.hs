{-
©AngelaMos | 2026
Engine.hs
-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Aenebris.WAF.Engine
  ( WafDecision(..)
  , MatchResult(..)
  , evaluatePhase1
  , wafMiddleware
  , wafResponseHeader
  , extractTargets
  , detectAmbiguousFraming
  , detectObsoleteLineFolding
  , detectDuplicateHost
  , runOperator
  , scoreFromMatches
  , decisionFromScore
  ) where

import Aenebris.WAF.Rule
  ( Action(..)
  , Operator(..)
  , Phase(..)
  , Rule(..)
  , RuleSet(..)
  , Severity(..)
  , Target(..)
  , runRegex
  , severityScore
  )
import Control.Concurrent.STM (TVar, readTVarIO)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.CaseInsensitive (CI)
import qualified Data.CaseInsensitive as CI
import Data.Char (toLower)
import Data.Word (Word32)
import Network.HTTP.Types (status403)
import Network.HTTP.Types.URI (urlDecode)
import Network.Wai
  ( Middleware
  , Request
  , rawPathInfo
  , rawQueryString
  , requestHeaders
  , requestMethod
  , responseLBS
  )

data MatchResult = MatchResult
  { mrRuleId :: !Word32
  , mrRuleName :: !ByteString
  , mrSeverity :: !Severity
  , mrAction :: !Action
  } deriving (Eq, Show)

data WafDecision
  = Allow
  | Deny !Int ![MatchResult]
  deriving (Eq, Show)

extractTargets :: Request -> Target -> [ByteString]
extractTargets req t = case t of
  TargetMethod -> [requestMethod req]
  TargetPath -> [rawPathInfo req, urlDecode True (rawPathInfo req)]
  TargetQuery -> [rawQueryString req, urlDecode True (rawQueryString req)]
  TargetHeaderValue name ->
    [v | (n, v) <- requestHeaders req, n == CI.mk name]
  TargetAnyHeaderName ->
    [CI.original n | (n, _) <- requestHeaders req]
  TargetAnyHeaderValue ->
    [v | (_, v) <- requestHeaders req]
  TargetHost ->
    [v | (n, v) <- requestHeaders req, n == CI.mk "host"]
  TargetUserAgent ->
    [v | (n, v) <- requestHeaders req, n == CI.mk "user-agent"]

runOperator :: Operator -> ByteString -> Bool
runOperator op input = case op of
  OpRegex r -> runRegex r input
  OpStreq s -> BC.map toLower input == BC.map toLower s
  OpContains s ->
    let needle = BC.map toLower s
        hay = BC.map toLower input
     in BS.isInfixOf needle hay
  OpAnyMatch ss ->
    let hay = BC.map toLower input
     in any (\s -> BS.isInfixOf (BC.map toLower s) hay) ss

ruleMatches :: Request -> Rule -> Bool
ruleMatches req r =
  case ruleOp r of
    OpStreq "__synthetic__" -> syntheticMatches req r
    op ->
      let inputs = concatMap (extractTargets req) (ruleTargets r)
       in any (runOperator op) inputs

syntheticMatches :: Request -> Rule -> Bool
syntheticMatches req r = case ruleName r of
  "ambiguous-framing-cl-te" -> detectAmbiguousFraming req
  "obsolete-line-folding" -> detectObsoleteLineFolding req
  "duplicate-host-header" -> detectDuplicateHost req
  _ -> False

detectAmbiguousFraming :: Request -> Bool
detectAmbiguousFraming req =
  let hs = requestHeaders req
      hasCL = any ((== CI.mk "content-length") . fst) hs
      hasTE = any ((== CI.mk "transfer-encoding") . fst) hs
   in hasCL && hasTE

detectObsoleteLineFolding :: Request -> Bool
detectObsoleteLineFolding req =
  let hs = requestHeaders req
   in any (containsLineFolding . snd) hs
  where
    containsLineFolding bs =
      let bytes = BS.unpack bs
       in hasFold bytes
    hasFold (a : b : c : rest)
      | a == 0x0d && b == 0x0a && (c == 0x20 || c == 0x09) = True
      | otherwise = hasFold (b : c : rest)
    hasFold (a : b : _)
      | (a == 0x0a) && (b == 0x20 || b == 0x09) = True
    hasFold _ = False

detectDuplicateHost :: Request -> Bool
detectDuplicateHost req =
  let hostCount = length [n | (n, _) <- requestHeaders req, n == CI.mk "host"]
   in hostCount > 1

scoreFromMatches :: [MatchResult] -> Int
scoreFromMatches = sum . map (severityScore . mrSeverity)

evaluatePhase1 :: RuleSet -> Request -> ([MatchResult], WafDecision)
evaluatePhase1 rs req =
  let activeRules = filter (\r -> rulePhase r == PhaseHeaders
                                  && ruleParanoia r <= rsParanoia rs)
                           (rsRules rs)
      matches =
        [ MatchResult (ruleId r) (ruleName r) (ruleSeverity r) (ruleAction r)
        | r <- activeRules, ruleMatches req r
        ]
      hasBlock = any ((== Block) . mrAction) matches
      score = scoreFromMatches matches
      decision = decisionFromScore hasBlock score (rsInboundThreshold rs) matches
   in (matches, decision)

decisionFromScore :: Bool -> Int -> Int -> [MatchResult] -> WafDecision
decisionFromScore hasBlock score threshold matches
  | hasBlock = Deny score matches
  | score >= threshold = Deny score matches
  | otherwise = Allow

wafResponseHeader :: CI ByteString
wafResponseHeader = "x-aenebris-waf"

wafMiddleware :: TVar RuleSet -> Middleware
wafMiddleware rsVar app req respond = do
  rs <- readTVarIO rsVar
  let (_matches, decision) = evaluatePhase1 rs req
  case decision of
    Allow -> app req respond
    Deny score _ ->
      respond $ responseLBS status403
        [ ("Content-Type", "text/plain; charset=utf-8")
        , (wafResponseHeader, "blocked score=" <> BC.pack (show score))
        ]
        "403 Forbidden - request blocked by Aenebris WAF"
