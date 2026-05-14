{-
©AngelaMos | 2026
Rule.hs
-}
{-# LANGUAGE OverloadedStrings #-}

module Aenebris.WAF.Rule
  ( Rule(..)
  , Operator(..)
  , Action(..)
  , Severity(..)
  , Phase(..)
  , Target(..)
  , ParanoiaLevel(..)
  , RuleSet(..)
  , severityScore
  , defaultInboundThreshold
  , defaultOutboundThreshold
  , compileRegex
  , CompiledRegex
  , runRegex
  ) where

import Data.ByteString (ByteString)
import Data.Word (Word32)
import Text.Regex.TDFA (Regex)
import Text.Regex.TDFA.ByteString (compile, execute)
import qualified Text.Regex.TDFA as TDFA

data Phase
  = PhaseHeaders
  | PhaseRequestBody
  | PhaseResponseHeaders
  | PhaseResponseBody
  deriving (Eq, Show, Ord)

data Severity
  = SevNotice
  | SevWarning
  | SevError
  | SevCritical
  deriving (Eq, Show, Ord)

severityScore :: Severity -> Int
severityScore SevNotice = 2
severityScore SevWarning = 3
severityScore SevError = 4
severityScore SevCritical = 5

data Action
  = Block
  | Score
  | Log
  | Pass
  deriving (Eq, Show)

data ParanoiaLevel
  = PL1
  | PL2
  | PL3
  | PL4
  deriving (Eq, Show, Ord, Enum, Bounded)

data Target
  = TargetMethod
  | TargetPath
  | TargetQuery
  | TargetHeaderValue !ByteString
  | TargetAnyHeaderName
  | TargetAnyHeaderValue
  | TargetHost
  | TargetUserAgent
  deriving (Eq, Show)

data CompiledRegex = CompiledRegex
  { unCompiledRegex      :: !Regex
  , compiledRegexPattern :: !ByteString
  }

instance Show CompiledRegex where
  show r = "<CompiledRegex " ++ show (compiledRegexPattern r) ++ ">"

instance Eq CompiledRegex where
  a == b = compiledRegexPattern a == compiledRegexPattern b

data Operator
  = OpRegex !CompiledRegex
  | OpStreq !ByteString
  | OpContains !ByteString
  | OpAnyMatch ![ByteString]
  deriving (Eq, Show)

data Rule = Rule
  { ruleId :: !Word32
  , ruleName :: !ByteString
  , rulePhase :: !Phase
  , ruleOp :: !Operator
  , ruleTargets :: ![Target]
  , ruleSeverity :: !Severity
  , ruleAction :: !Action
  , ruleParanoia :: !ParanoiaLevel
  } deriving (Show)

data RuleSet = RuleSet
  { rsRules :: ![Rule]
  , rsParanoia :: !ParanoiaLevel
  , rsInboundThreshold :: !Int
  , rsOutboundThreshold :: !Int
  } deriving (Show)

defaultInboundThreshold :: Int
defaultInboundThreshold = 5

defaultOutboundThreshold :: Int
defaultOutboundThreshold = 4

compileRegex :: ByteString -> Either String CompiledRegex
compileRegex pat =
  case compile compOpts execOpts pat of
    Left err -> Left err
    Right r -> Right (CompiledRegex r pat)
  where
    compOpts = TDFA.defaultCompOpt { TDFA.caseSensitive = False }
    execOpts = TDFA.defaultExecOpt

runRegex :: CompiledRegex -> ByteString -> Bool
runRegex cr input =
  case execute (unCompiledRegex cr) input of
    Right (Just _) -> True
    _ -> False
