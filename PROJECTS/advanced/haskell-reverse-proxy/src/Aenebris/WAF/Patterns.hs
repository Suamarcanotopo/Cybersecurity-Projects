{-
©AngelaMos | 2026
Patterns.hs
-}
{-# LANGUAGE OverloadedStrings #-}

module Aenebris.WAF.Patterns
  ( defaultRuleSet
  , defaultRules
  , sqliRules
  , xssRules
  , traversalRules
  , crlfRules
  , protocolRules
  , ruleNamePrefix
  ) where

import Aenebris.WAF.Rule
  ( Action(..)
  , Operator(..)
  , ParanoiaLevel(..)
  , Phase(..)
  , Rule(..)
  , RuleSet(..)
  , Severity(..)
  , Target(..)
  , compileRegex
  , defaultInboundThreshold
  , defaultOutboundThreshold
  )
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC

mkRegex :: ByteString -> Operator
mkRegex pat = case compileRegex pat of
  Right r -> OpRegex r
  Left _ -> OpStreq pat

sqliPatterns :: [ByteString]
sqliPatterns =
  [ "(union[[:space:]]+(all[[:space:]]+)?select)"
  , "((select|insert|update|delete|drop|alter|create|truncate)[[:space:]]+.*[[:space:]]+(from|into|table|database))"
  , "(or[[:space:]]+1[[:space:]]*=[[:space:]]*1)"
  , "(and[[:space:]]+1[[:space:]]*=[[:space:]]*1)"
  , "(';|\";|--[[:space:]]|/\\*|\\*/)"
  , "((sleep|benchmark|pg_sleep|waitfor[[:space:]]+delay)[[:space:]]*\\()"
  , "(load_file[[:space:]]*\\(|into[[:space:]]+(out|dump)file)"
  , "(information_schema|sys\\.tables|pg_catalog|sqlite_master)"
  ]

xssPatterns :: [ByteString]
xssPatterns =
  [ "<[[:space:]]*script[[:space:]>]"
  , "javascript[[:space:]]*:"
  , "on(load|error|click|mouseover|focus|blur|submit|change|input)[[:space:]]*="
  , "<[[:space:]]*(iframe|embed|object|svg|math|details|marquee)[[:space:]>]"
  , "(eval|expression|alert|prompt|confirm|fromcharcode)[[:space:]]*\\("
  , "data[[:space:]]*:[[:space:]]*text/html"
  , "vbscript[[:space:]]*:"
  ]

traversalPatterns :: [ByteString]
traversalPatterns =
  [ "(\\.\\./|\\.\\.\\\\)"
  , "(%2e%2e[/\\\\%]|%252e%252e)"
  , "(/etc/(passwd|shadow|hosts|group)|c:\\\\windows\\\\system32)"
  , "(/proc/self/(environ|cmdline|maps)|/dev/(tcp|udp))"
  , "(\\.\\./){2,}"
  ]

crlfPatterns :: [ByteString]
crlfPatterns =
  [ "(%0d%0a|%0a%0d|%0a|%0d|\\r\\n|\\n\\r)"
  , "(set-cookie:|content-length:|location:|content-type:)"
  ]

ruleNamePrefix :: ByteString -> Int -> ByteString
ruleNamePrefix prefix n = prefix <> BC.pack (show n)

mkRules :: ParanoiaLevel
        -> Severity
        -> Phase
        -> [Target]
        -> ByteString
        -> [ByteString]
        -> Int
        -> [Rule]
mkRules pl sev ph targets prefix patterns startId =
  zipWith3
    (\i name pat -> Rule
      { ruleId = fromIntegral i
      , ruleName = name
      , rulePhase = ph
      , ruleOp = mkRegex pat
      , ruleTargets = targets
      , ruleSeverity = sev
      , ruleAction = Score
      , ruleParanoia = pl
      })
    [startId ..]
    [ruleNamePrefix prefix n | n <- [1 .. length patterns]]
    patterns

sqliRules :: [Rule]
sqliRules = mkRules PL1 SevCritical PhaseHeaders
  [TargetPath, TargetQuery]
  "sqli-" sqliPatterns 1000

xssRules :: [Rule]
xssRules = mkRules PL1 SevCritical PhaseHeaders
  [TargetPath, TargetQuery]
  "xss-" xssPatterns 2000

traversalRules :: [Rule]
traversalRules = mkRules PL1 SevError PhaseHeaders
  [TargetPath, TargetQuery]
  "traversal-" traversalPatterns 3000

crlfRules :: [Rule]
crlfRules = mkRules PL2 SevError PhaseHeaders
  [TargetPath, TargetQuery]
  "crlf-" crlfPatterns 4000

protocolRules :: [Rule]
protocolRules =
  [ Rule
      { ruleId = 9000
      , ruleName = "ambiguous-framing-cl-te"
      , rulePhase = PhaseHeaders
      , ruleOp = OpStreq "__synthetic__"
      , ruleTargets = []
      , ruleSeverity = SevCritical
      , ruleAction = Block
      , ruleParanoia = PL1
      }
  , Rule
      { ruleId = 9001
      , ruleName = "obsolete-line-folding"
      , rulePhase = PhaseHeaders
      , ruleOp = OpStreq "__synthetic__"
      , ruleTargets = []
      , ruleSeverity = SevCritical
      , ruleAction = Block
      , ruleParanoia = PL1
      }
  , Rule
      { ruleId = 9002
      , ruleName = "duplicate-host-header"
      , rulePhase = PhaseHeaders
      , ruleOp = OpStreq "__synthetic__"
      , ruleTargets = []
      , ruleSeverity = SevError
      , ruleAction = Block
      , ruleParanoia = PL1
      }
  ]

defaultRules :: [Rule]
defaultRules =
  protocolRules <> sqliRules <> xssRules <> traversalRules <> crlfRules

defaultRuleSet :: RuleSet
defaultRuleSet = RuleSet
  { rsRules = defaultRules
  , rsParanoia = PL2
  , rsInboundThreshold = defaultInboundThreshold
  , rsOutboundThreshold = defaultOutboundThreshold
  }
