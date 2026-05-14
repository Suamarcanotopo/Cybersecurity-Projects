{-
©AngelaMos | 2026
Spec.hs
-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Aenebris.Backend
  ( createRuntimeBackend
  , getConnectionCount
  , isHealthy
  , rbActiveConnections
  , rbConsecutiveFailures
  , rbServerId
  , rbWeight
  , recordFailure
  , recordSuccess
  , trackConnection
  , transitionToHealthy
  , transitionToRecovering
  , transitionToUnhealthy
  )
import Aenebris.Config
  ( Config(..)
  , DDoSConfig(..)
  , ListenConfig(..)
  , PathRoute(..)
  , Route(..)
  , Server(..)
  , Upstream(..)
  , defaultDDoSConfig
  , validateConfig
  )
import Aenebris.DDoS.ConnLimit
  ( currentCount
  , defaultConnLimitConfig
  , defaultPerIPLimit
  , ipBytesFromSockAddr
  , newConnLimiter
  , release
  , tryAcquire
  )
import Aenebris.DDoS.EarlyData
  ( earlyDataGuard
  , isEarlyData
  , isIdempotent
  , status425
  )
import Aenebris.DDoS.IPJail
  ( JailedEntry(..)
  , defaultJailCooldown
  , isJailed
  , jail
  , newIPJail
  , purgeExpired
  )
import Aenebris.DDoS.MemoryShed
  ( isShedding
  , memoryShedMiddleware
  , newMemoryShed
  , updateShedding
  )
import Aenebris.Fingerprint.JA4H
  ( acceptLanguagePrefix
  , computeJA4H
  , emptyHashPlaceholder
  , methodCode
  , parseCookieNames
  , parseCookiePairs
  , renderJA4H
  , versionCode
  )
import Aenebris.Geo
  ( AsnWindow(..)
  , Geo(..)
  , GeoAction(..)
  , GeoConfig(..)
  , GeoConfigYaml(..)
  , GeoDecision(..)
  , GeoInfo(..)
  , asnConcentrationScore
  , bumpAsnCounter
  , buildGeoConfig
  , countryBlocked
  , decideGeo
  , defaultGeoConcentrationThreshold
  , defaultGeoConcentrationWindowSeconds
  , defaultGeoJailCooldownSeconds
  , defaultGeoLanguage
  , emptyGeoInfo
  , geoMiddleware
  , geoResponseHeaderName
  , lookupGeo
  , openGeo
  , parseGeoAction
  , purgeAsnCounters
  , renderGeoHeader
  , sockAddrToIP
  )
import Aenebris.Honeypot
  ( HoneypotAction(..)
  , HoneypotConfig(..)
  , HoneypotConfigYaml(..)
  , buildHoneypotConfig
  , defaultHoneypotConfig
  , defaultLabyrinthFanout
  , defaultTrapPatterns
  , honeypotMiddleware
  , isAllowed
  , labyrinthBody
  , matchTrap
  , parseHoneypotAction
  , robotsTxtBody
  )
import Aenebris.LoadBalancer
  ( LoadBalancerStrategy(..)
  , createLoadBalancer
  , selectBackend
  )
import Aenebris.ML.Model
  ( Ensemble(..)
  , MissingType(..)
  , Objective(..)
  , SplitKind(..)
  , Tree(..)
  , currentEnsembleVersion
  , decisionTypeBits
  , defaultLeftFromDecisionType
  , defaultRootIndex
  , defaultSigmoidScale
  , ensembleTreeCount
  , kCategoricalMask
  , kDefaultLeftMask
  , kMissingTypeMask
  , kMissingTypeShift
  , leafSentinel
  , makeCategoricalStumpTree
  , makeDecisionType
  , makeLeafTree
  , makeStumpTree
  , makeStumpTreeWithMissing
  , maximumEnsembleVersion
  , minimumEnsembleVersion
  , missingTypeFromDecisionType
  , noChildIndex
  , nodeIsLeaf
  , parseObjective
  , renderObjective
  , splitKindFromDecisionType
  , treeNodeCount
  , validateEnsemble
  , validateTree
  )
import Aenebris.ML.Features
  ( FeatureContext(..)
  , FeatureVector(..)
  , acceptIsWildcard
  , acceptValueLengthCap
  , clamp01
  , commonBrowserMarkerThreshold
  , emptyFeatureContext
  , extractFeatures
  , featureNames
  , featureVectorLength
  , featureVectorToList
  , featureVectorToVector
  , headerCountCap
  , headerOrderIsCanonicalBrowser
  , methodIsIdempotent
  , normalizedRatio
  , pathDepth
  , pathDepthCap
  , pathEntropyMax
  , pathHasSuspiciousExtension
  , queryParamCountCap
  , secFetchModeIsValid
  , secFetchTripleIsCoherent
  , shannonEntropyBytes
  , uaContainsBotKeyword
  , uaContainsHeadlessMarker
  , uaIsCommonBrowser
  , uaPlatformConsistency
  , uaSecChConsistency
  , userAgentLengthCap
  )
import Aenebris.ML.Calibration
  ( Calibrator(..)
  , calibrate
  , fitIsotonic
  , fitPlatt
  )
import Aenebris.ML.Engine
  ( Decision(..)
  , DecisionDetails(..)
  , Engine(..)
  , EngineConfig(..)
  , defaultEngineConfig
  , makeEngine
  , runEngine
  , runEngineDecision
  )
import Aenebris.ML.Middleware
  ( MLMiddlewareConfig(..)
  , decisionResponseHeader
  , decisionToWireText
  , defaultMLMiddlewareConfig
  , mlBotDetectionMiddleware
  , scoreResponseHeader
  )
import Aenebris.ML.IForest
  ( IForest(..)
  , ITree(..)
  , defaultIForestNumTrees
  , defaultIForestSubsampleSize
  , eulerMascheroni
  , harmonicNumber
  , normalizationConstant
  , pathLength
  , scoreIForest
  )
import Aenebris.ML.Inference
  ( kZeroThreshold
  , predictProba
  , predictRaw
  , predictScore
  , sigmoidLink
  , walkTree
  )
import Aenebris.ML.Loader
  ( ParseError(..)
  , parseEnsemble
  )
import Aenebris.Net.IP (sockAddrToIPBytes)
import Aenebris.Middleware.Redirect (httpsRedirect, httpsRedirectWithPort)
import Aenebris.Middleware.Security
  ( addSecurityHeaders
  , defaultSecurityConfig
  , strictSecurityConfig
  , testingSecurityConfig
  )
import Aenebris.RateLimit
  ( Decision(..)
  , checkLimit
  , createRateLimiter
  , parseRateSpec
  , rateLimitMiddleware
  )
import Aenebris.WAF.Engine
  ( WafDecision(..)
  , detectAmbiguousFraming
  , detectDuplicateHost
  , detectObsoleteLineFolding
  , evaluatePhase1
  , wafMiddleware
  )
import Aenebris.WAF.Patterns (defaultRuleSet)
import Aenebris.WAF.Rule
  ( RuleSet(..)
  , Severity(..)
  , compileRegex
  , runRegex
  , severityScore
  )

import Control.Concurrent.STM
  ( atomically
  , modifyTVar'
  , newTVarIO
  , readTVar
  , readTVarIO
  )
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as LBS
import qualified Data.CaseInsensitive as CI
import qualified Data.IP as IP
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as VU
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Either (isLeft)
import Data.Int (Int8)
import Data.Maybe (isJust, isNothing)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word (Word32)
import Data.Yaml (decodeThrow)
import Network.HTTP.Types
  ( http10
  , http11
  , http20
  , methodGet
  , methodPost
  , status200
  , status301
  , status403
  , status429
  , status503
  )
import Network.Socket
  ( SockAddr(..)
  , tupleToHostAddress
  , tupleToHostAddress6
  )
import Network.Wai
  ( Application
  , Request
  , queryString
  , remoteHost
  , requestHeaders
  , requestMethod
  , responseLBS
  )
import Network.Wai.Test
  ( defaultRequest
  , request
  , runSession
  , setPath
  , simpleHeaders
  , simpleStatus
  )
import Test.Hspec
  ( Expectation
  , Spec
  , describe
  , expectationFailure
  , hspec
  , it
  , runIO
  , shouldBe
  , shouldNotBe
  , shouldReturn
  , shouldSatisfy
  )

okApp :: Application
okApp _ respond = respond (responseLBS status200 [("Content-Type", "text/plain")] "ok")

ipv4Addr :: (Int, Int, Int, Int) -> Int -> SockAddr
ipv4Addr (a, b, c, d) port =
  SockAddrInet
    (fromIntegral port)
    (tupleToHostAddress (fromIntegral a, fromIntegral b, fromIntegral c, fromIntegral d))

requestFromIP :: SockAddr -> Request
requestFromIP addr = Network.Wai.Test.defaultRequest { remoteHost = addr }

countryDbPath, asnDbPath :: FilePath
countryDbPath = "test/fixtures/geo/GeoLite2-Country-Test.mmdb"
asnDbPath = "test/fixtures/geo/GeoLite2-ASN-Test.mmdb"

baseGeoConfig :: GeoConfig
baseGeoConfig = GeoConfig
  { gcCountryDb = Just countryDbPath
  , gcAsnDb = Just asnDbPath
  , gcBlockedCountries = []
  , gcAllowedCountries = []
  , gcFlaggedAsns = []
  , gcConcentrationWindowSeconds = defaultGeoConcentrationWindowSeconds
  , gcConcentrationThreshold = defaultGeoConcentrationThreshold
  , gcJailCooldownSeconds = defaultGeoJailCooldownSeconds
  , gcAction = GeoActionLog
  , gcAnnotateHeader = True
  , gcLanguage = defaultGeoLanguage
  }

main :: IO ()
main = hspec $ do
  configSpec
  loadBalancerSpec
  backendSpec
  securitySpec
  redirectSpec
  rateLimitSpec
  earlyDataSpec
  ipJailSpec
  memoryShedSpec
  connLimitSpec
  ja4hSpec
  wafSpec
  honeypotSpec
  geoSpec
  netIpSpec
  mlFeaturesSpec
  mlModelSpec
  mlLoaderSpec
  mlInferenceSpec
  mlCalibrationSpec
  mlIForestSpec
  mlEngineSpec
  mlMiddlewareSpec

configSpec :: Spec
configSpec = describe "Config" $ do
  it "validates a minimal valid config" $ do
    let cfg = Config
          { configVersion = 1
          , configListen = [ListenConfig 8080 Nothing Nothing]
          , configUpstreams = [Upstream "api" [Server "localhost:9000" 1] Nothing]
          , configRoutes = [Route "example.com" [PathRoute "/" "api" Nothing]]
          , configRateLimit = Nothing
          , configDDoS = Nothing
          , configHoneypot = Nothing
          , configGeo = Nothing
          }
    validateConfig cfg `shouldBe` Right ()

  it "rejects unsupported version" $ do
    let cfg = Config
          { configVersion = 2
          , configListen = [ListenConfig 8080 Nothing Nothing]
          , configUpstreams = [Upstream "api" [Server "localhost:9000" 1] Nothing]
          , configRoutes = [Route "example.com" [PathRoute "/" "api" Nothing]]
          , configRateLimit = Nothing
          , configDDoS = Nothing
          , configHoneypot = Nothing
          , configGeo = Nothing
          }
    validateConfig cfg `shouldSatisfy` isLeftWith "Unsupported"

  it "rejects invalid port numbers" $ do
    let cfg = Config
          { configVersion = 1
          , configListen = [ListenConfig 0 Nothing Nothing]
          , configUpstreams = [Upstream "api" [Server "localhost:9000" 1] Nothing]
          , configRoutes = [Route "example.com" [PathRoute "/" "api" Nothing]]
          , configRateLimit = Nothing
          , configDDoS = Nothing
          , configHoneypot = Nothing
          , configGeo = Nothing
          }
    validateConfig cfg `shouldSatisfy` isLeftWith "Invalid port"

  it "rejects unknown upstream references" $ do
    let cfg = Config
          { configVersion = 1
          , configListen = [ListenConfig 8080 Nothing Nothing]
          , configUpstreams = [Upstream "api" [Server "localhost:9000" 1] Nothing]
          , configRoutes = [Route "example.com" [PathRoute "/" "missing" Nothing]]
          , configRateLimit = Nothing
          , configDDoS = Nothing
          , configHoneypot = Nothing
          , configGeo = Nothing
          }
    validateConfig cfg `shouldSatisfy` isLeftWith "Unknown upstream"

  it "rejects duplicate upstream names" $ do
    let cfg = Config
          { configVersion = 1
          , configListen = [ListenConfig 8080 Nothing Nothing]
          , configUpstreams =
              [ Upstream "api" [Server "localhost:9000" 1] Nothing
              , Upstream "api" [Server "localhost:9001" 1] Nothing
              ]
          , configRoutes = [Route "example.com" [PathRoute "/" "api" Nothing]]
          , configRateLimit = Nothing
          , configDDoS = Nothing
          , configHoneypot = Nothing
          , configGeo = Nothing
          }
    validateConfig cfg `shouldSatisfy` isLeftWith "unique"

  it "parses ddos config from yaml" $ do
    let yaml = BC.pack $ unlines
          [ "early_data_reject: true"
          , "per_ip_connections: 32"
          , "reuse_port: true"
          ]
    parsed <- decodeThrow yaml :: IO DDoSConfig
    ddosPerIPConnections parsed `shouldBe` Just 32
    ddosReusePort parsed `shouldBe` True
    ddosEarlyDataReject parsed `shouldBe` True

  it "uses defaults for missing ddos fields" $ do
    let cfg = defaultDDoSConfig
    ddosEarlyDataReject cfg `shouldBe` True
    ddosReusePort cfg `shouldBe` False
    ddosPerIPConnections cfg `shouldBe` Nothing

loadBalancerSpec :: Spec
loadBalancerSpec = describe "LoadBalancer" $ do
  it "returns Nothing when no backends are healthy" $ do
    lb <- createLoadBalancer RoundRobin []
    selectBackend lb `shouldReturn` Nothing

  it "round robin distributes evenly across the pool" $ do
    bks <- mapM (\(i, h) -> createRuntimeBackend i (Server h 1))
                [(0, "host-a:80"), (1, "host-b:80"), (2, "host-c:80")]
    lb <- createLoadBalancer RoundRobin bks
    let totalRounds = 9 :: Int
    selections <- mapM
      (\_ -> fmap (fmap rbServerId) (selectBackend lb))
      [1 .. totalRounds]
    let counts =
          [ length (filter (== Just sid) selections)
          | sid <- [0, 1, 2]
          ]
    counts `shouldBe` [3, 3, 3]

  it "weighted round robin selects proportionally" $ do
    bks <- mapM (\(i, h, w) -> createRuntimeBackend i (Server h w))
                [(0, "host-a:80", 1), (1, "host-b:80", 4)]
    lb <- createLoadBalancer WeightedRoundRobin bks
    let totalRounds = 50 :: Int
    selections <- mapM
      (\_ -> fmap (fmap rbServerId) (selectBackend lb))
      [1 .. totalRounds]
    let countA = length (filter (== Just 0) selections)
        countB = length (filter (== Just 1) selections)
    countB `shouldSatisfy` (>= 35)
    countA `shouldSatisfy` (<= 15)

  it "least connections picks the backend with fewest active connections" $ do
    bks <- mapM (\(i, h) -> createRuntimeBackend i (Server h 1))
                [(0, "host-a:80"), (1, "host-b:80")]
    case bks of
      [a, _b] -> do
        atomically $
          modifyTVar'
            (rbActiveConnections a)
            (+ 5)
        lb <- createLoadBalancer LeastConnections bks
        selected <- selectBackend lb
        fmap rbServerId selected `shouldBe` Just 1
      _ -> expectationFailure "expected exactly two backends"

backendSpec :: Spec
backendSpec = describe "Backend" $ do
  it "starts a backend in healthy state" $ do
    bk <- createRuntimeBackend 0 (Server "host:80" 1)
    healthy <- atomically (isHealthy bk)
    healthy `shouldBe` True

  it "tracks transitions through unhealthy and recovering" $ do
    bk <- createRuntimeBackend 0 (Server "host:80" 1)
    atomically (transitionToUnhealthy bk)
    atomically (isHealthy bk) `shouldReturn` False
    atomically (transitionToRecovering bk)
    atomically (transitionToHealthy bk)
    atomically (isHealthy bk) `shouldReturn` True

  it "reports starting weight" $ do
    bk <- createRuntimeBackend 0 (Server "host:80" 7)
    rbWeight bk `shouldBe` 7

  it "starts with zero connections" $ do
    bk <- createRuntimeBackend 0 (Server "host:80" 1)
    atomically (getConnectionCount bk) `shouldReturn` 0

  it "transitions to Unhealthy after maxFailures consecutive failures" $ do
    bk <- createRuntimeBackend 0 (Server "host:80" 10)
    atomically (recordFailure bk 3)
    atomically (isHealthy bk) `shouldReturn` True
    atomically (recordFailure bk 3)
    atomically (isHealthy bk) `shouldReturn` True
    atomically (recordFailure bk 3)
    atomically (isHealthy bk) `shouldReturn` False

  it "recordSuccess on Healthy resets the failure counter" $ do
    bk <- createRuntimeBackend 0 (Server "host:80" 5)
    atomically (recordFailure bk 5)
    atomically (readTVar (rbConsecutiveFailures bk)) `shouldReturn` 1
    atomically (recordSuccess bk 5)
    atomically (readTVar (rbConsecutiveFailures bk)) `shouldReturn` 0

securitySpec :: Spec
securitySpec = describe "Security headers" $ do
  it "adds HSTS header in production preset" $ do
    let app = addSecurityHeaders defaultSecurityConfig okApp
    resp <- runSession (request Network.Wai.Test.defaultRequest) app
    let hs = simpleHeaders resp
    lookup "Strict-Transport-Security" hs `shouldSatisfy` isJust

  it "adds CSP header" $ do
    let app = addSecurityHeaders defaultSecurityConfig okApp
    resp <- runSession (request Network.Wai.Test.defaultRequest) app
    lookup "Content-Security-Policy" (simpleHeaders resp) `shouldSatisfy` isJust

  it "uses short HSTS max-age in testing preset" $ do
    let app = addSecurityHeaders testingSecurityConfig okApp
    resp <- runSession (request Network.Wai.Test.defaultRequest) app
    case lookup "Strict-Transport-Security" (simpleHeaders resp) of
      Just v -> v `shouldSatisfy` BS.isInfixOf "300"
      Nothing -> error "missing HSTS"

  it "applies strict preset with preload" $ do
    let app = addSecurityHeaders strictSecurityConfig okApp
    resp <- runSession (request Network.Wai.Test.defaultRequest) app
    case lookup "Strict-Transport-Security" (simpleHeaders resp) of
      Just v -> v `shouldSatisfy` BS.isInfixOf "preload"
      Nothing -> error "missing HSTS"

redirectSpec :: Spec
redirectSpec = describe "HTTPS redirect" $ do
  it "redirects insecure requests to https" $ do
    let app = httpsRedirect okApp
        req = setPath Network.Wai.Test.defaultRequest "/secret"
    resp <- runSession (request req) app
    simpleStatus resp `shouldBe` status301
    case lookup "Location" (simpleHeaders resp) of
      Just loc -> loc `shouldSatisfy` BS.isPrefixOf "https://"
      Nothing -> error "missing location"

  it "preserves path and query in redirect" $ do
    let app = httpsRedirectWithPort (Just 8443) okApp
        req = setPath Network.Wai.Test.defaultRequest "/p?x=1"
    resp <- runSession (request req) app
    case lookup "Location" (simpleHeaders resp) of
      Just loc -> do
        loc `shouldSatisfy` BS.isInfixOf ":8443"
        loc `shouldSatisfy` BS.isInfixOf "/p"
      Nothing -> error "missing location"

rateLimitSpec :: Spec
rateLimitSpec = describe "RateLimit" $ do
  it "parses well-formed rate spec" $ do
    parseRateSpec "100/minute" `shouldSatisfy` isJust
    parseRateSpec "10/s" `shouldSatisfy` isJust
    parseRateSpec "1/hour" `shouldSatisfy` isJust

  it "rejects malformed specs" $ do
    parseRateSpec "abc" `shouldBe` Nothing
    parseRateSpec "10/year" `shouldBe` Nothing
    parseRateSpec "0/s" `shouldBe` Nothing
    parseRateSpec "-5/s" `shouldBe` Nothing

  it "allows requests under capacity" $ do
    let spec = case parseRateSpec "10/s" of { Just s -> s; Nothing -> error "spec" }
    rl <- createRateLimiter spec
    now <- getPOSIXTime
    d1 <- atomically (checkLimit rl ("ip", "/") now)
    case d1 of
      Allowed _ -> pure ()
      _ -> error "expected allowed"

  it "denies after exhausting bucket" $ do
    let spec = case parseRateSpec "2/s" of { Just s -> s; Nothing -> error "spec" }
    rl <- createRateLimiter spec
    now <- getPOSIXTime
    _ <- atomically (checkLimit rl ("ip", "/") now)
    _ <- atomically (checkLimit rl ("ip", "/") now)
    d3 <- atomically (checkLimit rl ("ip", "/") now)
    case d3 of
      Denied _ -> pure ()
      _ -> error "expected denied"

  it "isolates buckets per key" $ do
    let spec = case parseRateSpec "1/s" of { Just s -> s; Nothing -> error "spec" }
    rl <- createRateLimiter spec
    now <- getPOSIXTime
    _ <- atomically (checkLimit rl ("a", "/") now)
    d <- atomically (checkLimit rl ("b", "/") now)
    case d of
      Allowed _ -> pure ()
      _ -> error "expected allowed for distinct key"

  it "returns 429 when rate limit exceeded via middleware" $ do
    let spec = case parseRateSpec "1/s" of { Just s -> s; Nothing -> error "spec" }
    rl <- createRateLimiter spec
    let app = rateLimitMiddleware rl okApp
    _ <- runSession (request Network.Wai.Test.defaultRequest) app
    resp <- runSession (request Network.Wai.Test.defaultRequest) app
    simpleStatus resp `shouldBe` status429
    lookup "Retry-After" (simpleHeaders resp) `shouldSatisfy` isJust

earlyDataSpec :: Spec
earlyDataSpec = describe "EarlyData" $ do
  it "treats GET as idempotent" $ do
    let req = Network.Wai.Test.defaultRequest { requestMethod = methodGet }
    isIdempotent req `shouldBe` True

  it "treats POST as non-idempotent" $ do
    let req = Network.Wai.Test.defaultRequest { requestMethod = methodPost }
    isIdempotent req `shouldBe` False

  it "detects Early-Data: 1 header" $ do
    let req = Network.Wai.Test.defaultRequest
          { requestHeaders = [("Early-Data", "1")] }
    isEarlyData req `shouldBe` True

  it "rejects POST in 0-RTT with 425" $ do
    let app = earlyDataGuard okApp
        req = Network.Wai.Test.defaultRequest
                { requestMethod = methodPost
                , requestHeaders = [("Early-Data", "1")]
                }
    resp <- runSession (request req) app
    simpleStatus resp `shouldBe` status425

  it "passes GET in 0-RTT through" $ do
    let app = earlyDataGuard okApp
        req = Network.Wai.Test.defaultRequest
                { requestMethod = methodGet
                , requestHeaders = [("Early-Data", "1")]
                }
    resp <- runSession (request req) app
    simpleStatus resp `shouldBe` status200

ipJailSpec :: Spec
ipJailSpec = describe "IPJail" $ do
  it "starts empty" $ do
    j <- newIPJail
    now <- getPOSIXTime
    res <- atomically (isJailed j "1.2.3.4" now)
    res `shouldBe` Nothing

  it "jails an IP and reports it" $ do
    j <- newIPJail
    now <- getPOSIXTime
    atomically (jail j "1.2.3.4" 60 "test" now)
    res <- atomically (isJailed j "1.2.3.4" now)
    case res of
      Just e -> jeReason e `shouldBe` "test"
      Nothing -> error "expected jailed"

  it "expires entries after cooldown" $ do
    j <- newIPJail
    now <- getPOSIXTime
    atomically (jail j "1.2.3.4" 1 "test" now)
    res <- atomically (isJailed j "1.2.3.4" (now + 5))
    res `shouldSatisfy` isNothing

  it "purges expired entries" $ do
    j <- newIPJail
    now <- getPOSIXTime
    atomically (jail j "1.1.1.1" 1 "x" now)
    atomically (jail j "2.2.2.2" 100 "y" now)
    purged <- atomically (purgeExpired j (now + 10))
    purged `shouldBe` 1

  it "default cooldown is 300s" $
    defaultJailCooldown `shouldBe` 300

memoryShedSpec :: Spec
memoryShedSpec = describe "MemoryShed" $ do
  it "starts not shedding" $ do
    ms <- newMemoryShed
    atomically (isShedding ms) `shouldReturn` False

  it "respects updateShedding flag" $ do
    ms <- newMemoryShed
    atomically (updateShedding ms True)
    atomically (isShedding ms) `shouldReturn` True

  it "returns 503 when shedding" $ do
    ms <- newMemoryShed
    atomically (updateShedding ms True)
    let app = memoryShedMiddleware ms okApp
    resp <- runSession (request Network.Wai.Test.defaultRequest) app
    simpleStatus resp `shouldBe` status503

  it "passes through when not shedding" $ do
    ms <- newMemoryShed
    let app = memoryShedMiddleware ms okApp
    resp <- runSession (request Network.Wai.Test.defaultRequest) app
    simpleStatus resp `shouldBe` status200

connLimitSpec :: Spec
connLimitSpec = describe "ConnLimit" $ do
  it "default per-IP limit is 16" $
    defaultPerIPLimit `shouldBe` 16

  it "encodes ipv4 sockaddr to bytes" $ do
    let addr = ipv4Addr (10, 0, 0, 1) 1234
    ipBytesFromSockAddr addr `shouldBe` "10.0.0.1"

  it "tryAcquire succeeds under limit" $ do
    cl <- newConnLimiter defaultConnLimitConfig
    ok <- atomically (tryAcquire cl "1.2.3.4")
    ok `shouldBe` True

  it "tryAcquire fails after limit" $ do
    cl <- newConnLimiter defaultConnLimitConfig
    let go 0 = pure ()
        go n = atomically (tryAcquire cl "9.9.9.9") >> go (n - 1)
    go defaultPerIPLimit
    res <- atomically (tryAcquire cl "9.9.9.9")
    res `shouldBe` False

  it "release decrements counter back to 0" $ do
    cl <- newConnLimiter defaultConnLimitConfig
    _ <- atomically (tryAcquire cl "1.2.3.4")
    atomically (currentCount cl "1.2.3.4") `shouldReturn` 1
    atomically (release cl "1.2.3.4")
    atomically (currentCount cl "1.2.3.4") `shouldReturn` 0

ja4hSpec :: Spec
ja4hSpec = describe "JA4H fingerprint" $ do
  it "encodes GET as ge" $
    methodCode "GET" `shouldBe` "ge"

  it "encodes POST as po" $
    methodCode "POST" `shouldBe` "po"

  it "encodes http versions" $ do
    versionCode http20 `shouldBe` "20"
    versionCode http11 `shouldBe` "11"
    versionCode http10 `shouldBe` "10"

  it "computes JA4H for a basic request" $ do
    let req = Network.Wai.Test.defaultRequest
          { requestMethod = "GET"
          , requestHeaders =
              [ ("User-Agent", "curl/8.0")
              , ("Accept-Language", "en-US,en;q=0.9")
              ]
          }
        f = computeJA4H req
        rendered = renderJA4H f
    BS.length rendered `shouldSatisfy` (> 0)

  it "extracts accept-language prefix" $
    acceptLanguagePrefix "en-US,en;q=0.9" `shouldBe` "enus"

  it "produces empty hash placeholder for empty inputs" $
    BS.length emptyHashPlaceholder `shouldSatisfy` (> 0)

  it "parses cookie names" $ do
    let names = parseCookieNames [("Cookie", "a=1; b=2; c=3")]
    length names `shouldBe` 3

  it "parses cookie pairs" $ do
    let pairs = parseCookiePairs [("Cookie", "a=1; b=2")]
    length pairs `shouldBe` 2

wafSpec :: Spec
wafSpec = describe "WAF" $ do
  it "compiles a regex pattern" $ do
    let ok = case compileRegex "^foo" of
               Right _ -> True
               Left _ -> False
    ok `shouldBe` True

  it "runs a compiled regex" $ do
    let matched = case compileRegex "select" of
                    Right r -> runRegex r "SELECT * FROM users"
                    Left _ -> False
    matched `shouldBe` True

  it "scores severity correctly" $ do
    severityScore SevCritical `shouldBe` 5
    severityScore SevError `shouldBe` 4
    severityScore SevWarning `shouldBe` 3
    severityScore SevNotice `shouldBe` 2

  it "Eq CompiledRegex is reflexive (x == x)" $
    case compileRegex "abc" of
      Right r -> r `shouldBe` r
      Left err -> expectationFailure err

  it "Eq CompiledRegex distinguishes different patterns" $
    case (compileRegex "abc", compileRegex "def") of
      (Right r1, Right r2) -> (r1 == r2) `shouldBe` False
      _ -> expectationFailure "expected both to compile"

  it "default ruleset includes rules" $
    length (rsRules defaultRuleSet) `shouldSatisfy` (> 0)

  it "evaluatePhase1 returns a decision for clean request" $ do
    let req = Network.Wai.Test.defaultRequest
          { requestHeaders = [("Host", "example.com")] }
        (_, dec) = evaluatePhase1 defaultRuleSet req
        valid = case dec of
                  Allow -> True
                  Deny _ _ -> True
    valid `shouldBe` True

  it "wafMiddleware allows clean GET" $ do
    tv <- newTVarIO defaultRuleSet
    let app = wafMiddleware tv okApp
    resp <- runSession (request Network.Wai.Test.defaultRequest) app
    simpleStatus resp `shouldBe` status200

  it "detects ambiguous framing (CL+TE)" $ do
    let req = Network.Wai.Test.defaultRequest
          { requestHeaders =
              [ ("Content-Length", "10")
              , ("Transfer-Encoding", "chunked")
              ]
          }
    detectAmbiguousFraming req `shouldBe` True

  it "detects duplicate Host headers" $ do
    let req = Network.Wai.Test.defaultRequest
          { requestHeaders = [("Host", "a"), ("Host", "b")] }
    detectDuplicateHost req `shouldBe` True

  it "detects obsolete line folding" $ do
    let req = Network.Wai.Test.defaultRequest
          { requestHeaders = [("X-Custom", "first\r\n continued")] }
    detectObsoleteLineFolding req `shouldBe` True

honeypotSpec :: Spec
honeypotSpec = describe "Honeypot" $ do
  it "matches exact trap path" $
    matchTrap "/.env" defaultTrapPatterns `shouldNotBe` Nothing

  it "matches prefix trap" $
    matchTrap "/.git/config" defaultTrapPatterns `shouldNotBe` Nothing

  it "ignores non-trap path" $
    matchTrap "/api/users" defaultTrapPatterns `shouldBe` Nothing

  it "respects allowed-IPs list" $
    isAllowed "10.0.0.1" ["10.0.0.1"] `shouldBe` True

  it "parses honeypot action strings" $ do
    parseHoneypotAction "jail" `shouldBe` HoneypotJail
    parseHoneypotAction "labyrinth" `shouldBe` HoneypotLabyrinth
    parseHoneypotAction "log" `shouldBe` HoneypotLog
    parseHoneypotAction "" `shouldBe` HoneypotLog

  it "buildHoneypotConfig returns Nothing when disabled" $ do
    let yaml = HoneypotConfigYaml
          { hpyEnabled = False
          , hpyAction = "jail"
          , hpyCooldownSeconds = Nothing
          , hpyResponseDelayMillis = Nothing
          , hpyExtraExact = []
          , hpyExtraPrefix = []
          , hpyUseDefaults = True
          , hpyAllowedIPs = []
          , hpyServeRobotsTxt = True
          , hpyLabyrinthFanout = Nothing
          }
    buildHoneypotConfig (Just yaml) `shouldBe` Nothing

  it "builds enabled config with defaults" $ do
    let yaml = HoneypotConfigYaml
          { hpyEnabled = True
          , hpyAction = "log"
          , hpyCooldownSeconds = Just 600
          , hpyResponseDelayMillis = Nothing
          , hpyExtraExact = ["/myapp"]
          , hpyExtraPrefix = []
          , hpyUseDefaults = True
          , hpyAllowedIPs = ["10.0.0.1"]
          , hpyServeRobotsTxt = True
          , hpyLabyrinthFanout = Nothing
          }
    case buildHoneypotConfig (Just yaml) of
      Just cfg -> do
        hpAction cfg `shouldBe` HoneypotLog
        hpJailCooldown cfg `shouldBe` 600
        length (hpAllowedIPs cfg) `shouldBe` 1
      Nothing -> error "expected config"

  it "labyrinth body has content" $ do
    let body = labyrinthBody "/_labyrinth/abc" defaultLabyrinthFanout
    LBS.length body `shouldSatisfy` (> 0)

  it "robots.txt body has content" $ do
    let body = robotsTxtBody defaultHoneypotConfig
    BS.length body `shouldSatisfy` (> 0)

  it "honeypot middleware traps env path" $ do
    let app = honeypotMiddleware defaultHoneypotConfig Nothing okApp
        req = setPath Network.Wai.Test.defaultRequest "/.env"
    resp <- runSession (request req) app
    simpleStatus resp `shouldNotBe` status200

  it "honeypot middleware passes clean path" $ do
    let app = honeypotMiddleware defaultHoneypotConfig Nothing okApp
        req = setPath Network.Wai.Test.defaultRequest "/api/users"
    resp <- runSession (request req) app
    simpleStatus resp `shouldBe` status200

geoSpec :: Spec
geoSpec = describe "Geo/ASN" $ do
  it "default language is en" $
    defaultGeoLanguage `shouldBe` "en"

  it "defaults: window=60s, threshold=500, cooldown=600s" $ do
    defaultGeoConcentrationWindowSeconds `shouldBe` 60
    defaultGeoConcentrationThreshold `shouldBe` 500
    defaultGeoJailCooldownSeconds `shouldBe` 600

  it "geo response header is x-aenebris-geo" $
    geoResponseHeaderName `shouldBe` "x-aenebris-geo"

  it "parseGeoAction handles canonical strings" $ do
    parseGeoAction "jail" `shouldBe` GeoActionJail
    parseGeoAction "log" `shouldBe` GeoActionLog
    parseGeoAction "JAIL" `shouldBe` GeoActionJail
    parseGeoAction "" `shouldBe` GeoActionLog

  it "sockAddrToIP converts ipv4" $ do
    let addr = ipv4Addr (1, 2, 3, 4) 0
        isV4 = case sockAddrToIP addr of
                 Just (IP.IPv4 _) -> True
                 _ -> False
    isV4 `shouldBe` True

  it "sockAddrToIP converts ipv6" $ do
    let ha6 = tupleToHostAddress6 (0x2001, 0xdb8, 0, 0, 0, 0, 0, 1)
        addr = SockAddrInet6 0 0 ha6 0
        isV6 = case sockAddrToIP addr of
                 Just (IP.IPv6 _) -> True
                 _ -> False
    isV6 `shouldBe` True

  it "sockAddrToIP returns Nothing for unix" $
    sockAddrToIP (SockAddrUnix "/tmp/sock") `shouldBe` Nothing

  it "countryBlocked: empty config allows all" $ do
    countryBlocked baseGeoConfig (Just "US") `shouldBe` Nothing
    countryBlocked baseGeoConfig Nothing `shouldBe` Nothing

  it "countryBlocked: blocklist matches case-insensitive" $ do
    let cfg = baseGeoConfig { gcBlockedCountries = ["US"] }
    countryBlocked cfg (Just "us") `shouldBe` Just "US"
    countryBlocked cfg (Just "US") `shouldBe` Just "US"
    countryBlocked cfg (Just "GB") `shouldBe` Nothing

  it "countryBlocked: allowlist denies others" $ do
    let cfg = baseGeoConfig { gcAllowedCountries = ["US"] }
    countryBlocked cfg (Just "US") `shouldBe` Nothing
    countryBlocked cfg (Just "RU") `shouldBe` Just "RU"

  it "countryBlocked: missing iso with allowlist returns ??" $ do
    let cfg = baseGeoConfig { gcAllowedCountries = ["US"] }
    countryBlocked cfg Nothing `shouldBe` Just "??"

  it "buildGeoConfig: returns Nothing when disabled" $ do
    let yaml = GeoConfigYaml
          { gcyEnabled = False
          , gcyCountryDb = Nothing
          , gcyAsnDb = Nothing
          , gcyBlockedCountries = []
          , gcyAllowedCountries = []
          , gcyFlaggedAsns = []
          , gcyWindowSeconds = Nothing
          , gcyThreshold = Nothing
          , gcyJailCooldownSeconds = Nothing
          , gcyAction = Nothing
          , gcyAnnotateHeader = True
          , gcyLanguage = Nothing
          }
    buildGeoConfig (Just yaml) `shouldBe` Nothing

  it "buildGeoConfig: returns Nothing for Nothing input" $
    buildGeoConfig Nothing `shouldBe` Nothing

  it "buildGeoConfig: enabled uses defaults" $ do
    let yaml = GeoConfigYaml
          { gcyEnabled = True
          , gcyCountryDb = Just countryDbPath
          , gcyAsnDb = Just asnDbPath
          , gcyBlockedCountries = ["ru", "kp"]
          , gcyAllowedCountries = []
          , gcyFlaggedAsns = [1234]
          , gcyWindowSeconds = Nothing
          , gcyThreshold = Nothing
          , gcyJailCooldownSeconds = Nothing
          , gcyAction = Just "jail"
          , gcyAnnotateHeader = True
          , gcyLanguage = Nothing
          }
    case buildGeoConfig (Just yaml) of
      Just cfg -> do
        gcCountryDb cfg `shouldBe` Just countryDbPath
        gcAsnDb cfg `shouldBe` Just asnDbPath
        gcBlockedCountries cfg `shouldBe` ["RU", "KP"]
        gcFlaggedAsns cfg `shouldBe` [1234]
        gcAction cfg `shouldBe` GeoActionJail
        gcConcentrationWindowSeconds cfg `shouldBe` defaultGeoConcentrationWindowSeconds
        gcConcentrationThreshold cfg `shouldBe` defaultGeoConcentrationThreshold
      Nothing -> error "expected config"

  it "lookupGeo finds country for known fixture IP" $ do
    g <- openGeo baseGeoConfig
    let ip = IP.IPv4 (read "2.125.160.216" :: IP.IPv4)
    info <- lookupGeo g ip
    giCountryISO info `shouldSatisfy` isJust

  it "lookupGeo finds ASN for known fixture IP" $ do
    g <- openGeo baseGeoConfig
    let ip = IP.IPv4 (read "1.128.0.0" :: IP.IPv4)
    info <- lookupGeo g ip
    giAsnNumber info `shouldBe` Just 1221

  it "lookupGeo flags ASN when configured" $ do
    let cfg = baseGeoConfig { gcFlaggedAsns = [1221] }
    g <- openGeo cfg
    let ip = IP.IPv4 (read "1.128.0.0" :: IP.IPv4)
    info <- lookupGeo g ip
    giFlaggedAsn info `shouldBe` True

  it "bumpAsnCounter starts at 1" $ do
    g <- openGeo baseGeoConfig
    now <- getPOSIXTime
    n <- atomically (bumpAsnCounter g 1234 now)
    n `shouldBe` 1

  it "bumpAsnCounter increments within window" $ do
    g <- openGeo baseGeoConfig
    now <- getPOSIXTime
    _ <- atomically (bumpAsnCounter g 1 now)
    _ <- atomically (bumpAsnCounter g 1 now)
    n <- atomically (bumpAsnCounter g 1 now)
    n `shouldBe` 3

  it "bumpAsnCounter resets after window" $ do
    let cfg = baseGeoConfig { gcConcentrationWindowSeconds = 1 }
    g <- openGeo cfg
    now <- getPOSIXTime
    _ <- atomically (bumpAsnCounter g 1 now)
    n <- atomically (bumpAsnCounter g 1 (now + 5))
    n `shouldBe` 1

  it "asnConcentrationScore is in [0,1]" $ do
    g <- openGeo baseGeoConfig
    asnConcentrationScore g 0 `shouldBe` 0.0
    asnConcentrationScore g defaultGeoConcentrationThreshold `shouldBe` 1.0
    asnConcentrationScore g (defaultGeoConcentrationThreshold * 5) `shouldBe` 1.0

  it "purgeAsnCounters removes expired entries" $ do
    let cfg = baseGeoConfig { gcConcentrationWindowSeconds = 1 }
    g <- openGeo cfg
    now <- getPOSIXTime
    _ <- atomically (bumpAsnCounter g 1 now)
    purged <- atomically (purgeAsnCounters g (now + 5))
    purged `shouldBe` 1

  it "decideGeo: clean info allows" $
    decideGeo baseGeoConfig emptyGeoInfo 0 `shouldBe` GeoAllow

  it "decideGeo: country block wins over asn" $ do
    let cfg = baseGeoConfig
                { gcBlockedCountries = ["RU"]
                , gcFlaggedAsns = [42]
                , gcAction = GeoActionJail
                }
        info = emptyGeoInfo
                { giCountryISO = Just "RU"
                , giAsnNumber = Just 42
                , giFlaggedAsn = True
                }
    decideGeo cfg info 9999 `shouldBe` GeoBlockCountry "RU"

  it "decideGeo: jail when flagged ASN above threshold and action=Jail" $ do
    let cfg = baseGeoConfig
                { gcFlaggedAsns = [42]
                , gcAction = GeoActionJail
                , gcConcentrationThreshold = 10
                }
        info = emptyGeoInfo
                { giCountryISO = Just "US"
                , giAsnNumber = Just 42
                , giFlaggedAsn = True
                }
    case decideGeo cfg info 100 of
      GeoJailAsn n _ -> n `shouldBe` 42
      _ -> error "expected GeoJailAsn"

  it "decideGeo: action=Log never jails" $ do
    let cfg = baseGeoConfig
                { gcFlaggedAsns = [42]
                , gcAction = GeoActionLog
                , gcConcentrationThreshold = 1
                }
        info = emptyGeoInfo
                { giAsnNumber = Just 42, giFlaggedAsn = True }
    decideGeo cfg info 1000 `shouldBe` GeoAllow

  it "decideGeo: below threshold allows" $ do
    let cfg = baseGeoConfig
                { gcFlaggedAsns = [42]
                , gcAction = GeoActionJail
                , gcConcentrationThreshold = 100
                }
        info = emptyGeoInfo { giAsnNumber = Just 42, giFlaggedAsn = True }
    decideGeo cfg info 50 `shouldBe` GeoAllow

  it "renderGeoHeader formats fields" $ do
    let info = GeoInfo (Just "US") (Just 1221) (Just "Telstra") False
        h = renderGeoHeader info 3
    h `shouldSatisfy` BS.isInfixOf "country=US"
    h `shouldSatisfy` BS.isInfixOf "asn=1221"
    h `shouldSatisfy` BS.isInfixOf "flag=0"
    h `shouldSatisfy` BS.isInfixOf "count=3"

  it "renderGeoHeader handles unknown fields" $ do
    let h = renderGeoHeader emptyGeoInfo 0
    h `shouldSatisfy` BS.isInfixOf "country=??"
    h `shouldSatisfy` BS.isInfixOf "asn=0"

  it "renderGeoHeader sets flag=1 when flagged" $ do
    let info = emptyGeoInfo { giFlaggedAsn = True }
        h = renderGeoHeader info 5
    h `shouldSatisfy` BS.isInfixOf "flag=1"

  it "geoMiddleware annotates response header" $ do
    g <- openGeo baseGeoConfig
    let app = geoMiddleware g Nothing okApp
        req = requestFromIP (ipv4Addr (1, 128, 0, 0) 0)
    resp <- runSession (request req) app
    lookup geoResponseHeaderName (simpleHeaders resp) `shouldSatisfy` isJust

  it "geoMiddleware blocks denied country" $ do
    let cfg = baseGeoConfig { gcBlockedCountries = ["GB"] }
    g <- openGeo cfg
    let app = geoMiddleware g Nothing okApp
        req = requestFromIP (ipv4Addr (2, 125, 160, 216) 0)
    resp <- runSession (request req) app
    simpleStatus resp `shouldBe` status403

  it "geoMiddleware allows clean country" $ do
    let cfg = baseGeoConfig { gcBlockedCountries = ["KP"] }
    g <- openGeo cfg
    let app = geoMiddleware g Nothing okApp
        req = requestFromIP (ipv4Addr (2, 125, 160, 216) 0)
    resp <- runSession (request req) app
    simpleStatus resp `shouldBe` status200

  it "geoMiddleware below-threshold flagged ASN passes" $ do
    let cfg = baseGeoConfig
                { gcFlaggedAsns = [1221]
                , gcAction = GeoActionJail
                , gcConcentrationThreshold = 1000
                }
    g <- openGeo cfg
    let app = geoMiddleware g Nothing okApp
        req = requestFromIP (ipv4Addr (1, 128, 0, 0) 0)
    resp <- runSession (request req) app
    simpleStatus resp `shouldBe` status200

  it "geoMiddleware above-threshold flagged ASN is blocked (jail action)" $ do
    let cfg = baseGeoConfig
                { gcFlaggedAsns = [1221]
                , gcAction = GeoActionJail
                , gcConcentrationThreshold = 1
                }
    g <- openGeo cfg
    let app = geoMiddleware g Nothing okApp
        req = requestFromIP (ipv4Addr (1, 128, 0, 0) 0)
    resp <- runSession (request req) app
    simpleStatus resp `shouldBe` status403

  it "geoMiddleware does not annotate when annotate_header=false" $ do
    let cfg = baseGeoConfig { gcAnnotateHeader = False }
    g <- openGeo cfg
    let app = geoMiddleware g Nothing okApp
        req = requestFromIP (ipv4Addr (1, 128, 0, 0) 0)
    resp <- runSession (request req) app
    lookup geoResponseHeaderName (simpleHeaders resp) `shouldBe` Nothing

  it "geoMiddleware bumps ASN counter" $ do
    g <- openGeo baseGeoConfig
    let app = geoMiddleware g Nothing okApp
        req = requestFromIP (ipv4Addr (1, 128, 0, 0) 0)
    _ <- runSession (request req) app
    _ <- runSession (request req) app
    counts <- readTVarIO (geoAsnCounts g)
    case Map.lookup 1221 counts of
      Just w -> awCount w `shouldSatisfy` (>= 1)
      Nothing -> error "expected ASN counter"

mlFeaturesSpec :: Spec
mlFeaturesSpec = describe "ML.Features" $ do
  it "advertises a fixed feature vector length of 28" $ do
    featureVectorLength `shouldBe` 28
    length featureNames `shouldBe` 28

  it "produces feature lists of the advertised length" $ do
    let req = headersOnlyRequest [("user-agent", "curl/8.4.0")]
        fv = extractFeatures emptyFeatureContext req
    length (featureVectorToList fv) `shouldBe` featureVectorLength

  it "produces unboxed vectors of the advertised length" $ do
    let req = headersOnlyRequest [("user-agent", "Mozilla/5.0")]
        v = featureVectorToVector (extractFeatures emptyFeatureContext req)
    VU.length v `shouldBe` featureVectorLength

  it "clamps values to [0,1]" $ do
    clamp01 (-1.0) `shouldBe` 0.0
    clamp01 0.0 `shouldBe` 0.0
    clamp01 0.5 `shouldBe` 0.5
    clamp01 1.0 `shouldBe` 1.0
    clamp01 7.5 `shouldBe` 1.0

  it "normalizedRatio handles zero cap safely" $
    normalizedRatio 1000 0.0 `shouldBe` 0.0

  it "normalizedRatio caps at 1.0" $
    normalizedRatio 1000 10.0 `shouldBe` 1.0

  it "normalizedRatio computes ratio mid-range" $
    normalizedRatio 4 8.0 `shouldBe` 0.5

  it "shannonEntropyBytes returns 0 for empty input" $
    shannonEntropyBytes "" `shouldBe` 0.0

  it "shannonEntropyBytes returns 0 for a single repeated byte" $
    shannonEntropyBytes "aaaaaaaa" `shouldBe` 0.0

  it "shannonEntropyBytes returns 1.0 for a balanced two-symbol input" $
    shannonEntropyBytes "abab" `shouldBe` 1.0

  it "shannonEntropyBytes is bounded by 8.0 (byte alphabet)" $ do
    let payload = BS.pack [0 .. 255]
    shannonEntropyBytes payload `shouldSatisfy` (<= pathEntropyMax + 1.0e-9)

  it "shannonEntropyBytes grows with diversity" $ do
    let low  = shannonEntropyBytes "/aaaaaa"
        high = shannonEntropyBytes "/abcdef"
    high `shouldSatisfy` (> low)

  it "pathDepth ignores empty segments" $ do
    pathDepth "/" `shouldBe` 0
    pathDepth "" `shouldBe` 0
    pathDepth "/foo" `shouldBe` 1
    pathDepth "/foo/bar" `shouldBe` 2
    pathDepth "/foo//bar/" `shouldBe` 2

  it "pathHasSuspiciousExtension flags scanner targets" $ do
    pathHasSuspiciousExtension "/wp-config.php" `shouldBe` True
    pathHasSuspiciousExtension "/site/.env" `shouldBe` True
    pathHasSuspiciousExtension "/backup.SQL" `shouldBe` True
    pathHasSuspiciousExtension "/.git" `shouldBe` True

  it "pathHasSuspiciousExtension is false for normal paths" $ do
    pathHasSuspiciousExtension "/" `shouldBe` False
    pathHasSuspiciousExtension "/api/v1/users" `shouldBe` False
    pathHasSuspiciousExtension "/static/app.js" `shouldBe` False

  it "methodIsIdempotent matches HTTP semantics" $ do
    methodIsIdempotent "GET" `shouldBe` True
    methodIsIdempotent "HEAD" `shouldBe` True
    methodIsIdempotent "OPTIONS" `shouldBe` True
    methodIsIdempotent "TRACE" `shouldBe` True
    methodIsIdempotent "POST" `shouldBe` False
    methodIsIdempotent "DELETE" `shouldBe` False
    methodIsIdempotent "PATCH" `shouldBe` False

  it "uaContainsBotKeyword catches common scraper UAs" $ do
    uaContainsBotKeyword "Googlebot/2.1" `shouldBe` True
    uaContainsBotKeyword "python-requests/2.31.0" `shouldBe` True
    uaContainsBotKeyword "curl/8.4.0" `shouldBe` True
    uaContainsBotKeyword "Wget/1.21" `shouldBe` True

  it "uaContainsBotKeyword does not flag normal Chrome" $
    uaContainsBotKeyword "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36"
      `shouldBe` False

  it "uaContainsHeadlessMarker catches automation tools" $ do
    uaContainsHeadlessMarker "HeadlessChrome/120.0.0.0" `shouldBe` True
    uaContainsHeadlessMarker "puppeteer-core/21.0.0" `shouldBe` True
    uaContainsHeadlessMarker "PhantomJS/2.1.1" `shouldBe` True
    uaContainsHeadlessMarker "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit Chrome Safari" `shouldBe` False

  it "uaIsCommonBrowser requires multiple browser markers" $ do
    uaIsCommonBrowser "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36"
      `shouldBe` True
    uaIsCommonBrowser "curl/8.4.0" `shouldBe` False
    uaIsCommonBrowser "Mozilla/5.0" `shouldBe` False
    commonBrowserMarkerThreshold `shouldBe` 2

  it "uaSecChConsistency returns 1 when no Sec-CH-UA is present" $
    uaSecChConsistency (Just "anything") Nothing `shouldBe` 1.0

  it "uaSecChConsistency returns 1 for matching Chromium UA + Sec-CH-UA" $
    uaSecChConsistency
      (Just "Mozilla/5.0 ... Chrome/120.0.0.0 Safari/537.36")
      (Just "\"Chromium\";v=\"120\"")
      `shouldBe` 1.0

  it "uaSecChConsistency returns 0 for spoofed Sec-CH-UA on a non-Chromium UA" $
    uaSecChConsistency
      (Just "Mozilla/5.0 (Macintosh) AppleWebKit Safari Firefox/120.0")
      (Just "\"Chromium\";v=\"120\"")
      `shouldBe` 0.0

  it "uaSecChConsistency returns 0 when UA is missing but Sec-CH-UA is present" $
    uaSecChConsistency Nothing (Just "\"Chromium\";v=\"120\"") `shouldBe` 0.0

  it "extractFeatures: bare scraper has high suspicion signal" $ do
    let req = headersOnlyRequest [("user-agent", "curl/8.4.0")]
        fv = extractFeatures emptyFeatureContext req
    fMissingAcceptLanguage fv `shouldBe` 1.0
    fMissingUserAgent fv `shouldBe` 0.0
    fMissingAcceptEncoding fv `shouldBe` 1.0
    fMissingReferer fv `shouldBe` 1.0
    fHasCookie fv `shouldBe` 0.0
    fHasSecChUa fv `shouldBe` 0.0
    fUaBotKeyword fv `shouldBe` 1.0
    fUaCommonBrowser fv `shouldBe` 0.0
    fUaSecChConsistent fv `shouldBe` 1.0

  it "extractFeatures: realistic Chrome request looks benign" $ do
    let req = headersOnlyRequest
          [ ("user-agent", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36")
          , ("accept-language", "en-US,en;q=0.9")
          , ("accept-encoding", "gzip, deflate, br")
          , ("referer", "https://example.com/")
          , ("cookie", "sessionid=abc123")
          , ("sec-ch-ua", "\"Chromium\";v=\"120\"")
          ]
        fv = extractFeatures emptyFeatureContext req
    fMissingAcceptLanguage fv `shouldBe` 0.0
    fMissingUserAgent fv `shouldBe` 0.0
    fMissingAcceptEncoding fv `shouldBe` 0.0
    fMissingReferer fv `shouldBe` 0.0
    fHasCookie fv `shouldBe` 1.0
    fHasSecChUa fv `shouldBe` 1.0
    fUaBotKeyword fv `shouldBe` 0.0
    fUaCommonBrowser fv `shouldBe` 1.0
    fUaSecChConsistent fv `shouldBe` 1.0

  it "extractFeatures: missing user agent flips fUaCommonBrowser off" $ do
    let req = headersOnlyRequest []
        fv = extractFeatures emptyFeatureContext req
    fMissingUserAgent fv `shouldBe` 1.0
    fUaCommonBrowser fv `shouldBe` 0.0
    fUaBotKeyword fv `shouldBe` 0.0
    fUaHeadless fv `shouldBe` 0.0
    fUaLength fv `shouldBe` 0.0

  it "extractFeatures: header_count is normalized by cap" $ do
    let manyHeaders = [(BC.pack ("x-h-" ++ show i), "v") | i <- [(1 :: Int) .. 16]]
        req = headersOnlyRequest manyHeaders
        fv = extractFeatures emptyFeatureContext req
    fHeaderCount fv `shouldBe` (fromIntegral (length manyHeaders) / headerCountCap)

  it "extractFeatures: header_count saturates above the cap" $ do
    let manyHeaders = [(BC.pack ("x-h-" ++ show i), "v") | i <- [(1 :: Int) .. 200]]
        req = headersOnlyRequest manyHeaders
        fv = extractFeatures emptyFeatureContext req
    fHeaderCount fv `shouldBe` 1.0

  it "extractFeatures: ua_length saturates at the cap" $ do
    let longUa = BS.replicate 1024 0x41
        req = headersOnlyRequest [("user-agent", longUa)]
        fv = extractFeatures emptyFeatureContext req
    fUaLength fv `shouldBe` 1.0

  it "extractFeatures: path depth and entropy reflect the path" $ do
    let req = pathOnlyRequest "/api/v1/users/42"
        fv = extractFeatures emptyFeatureContext req
    fPathDepth fv `shouldBe` (4 / pathDepthCap)
    fPathEntropy fv `shouldSatisfy` (\e -> e > 0.0 && e <= 1.0)

  it "extractFeatures: path entropy is bounded in [0,1]" $ do
    let req = pathOnlyRequest "/aaaaaaaa"
        fv = extractFeatures emptyFeatureContext req
    fPathEntropy fv `shouldSatisfy` (\e -> e >= 0.0 && e <= 1.0)

  it "extractFeatures: suspicious extension flag is set" $ do
    let req = pathOnlyRequest "/wp-login.php"
        fv = extractFeatures emptyFeatureContext req
    fSuspiciousPathExt fv `shouldBe` 1.0

  it "extractFeatures: query param count saturates at the cap" $ do
    let req = (pathOnlyRequest "/")
                { queryString =
                    [ (BC.pack ("k" ++ show i), Just "v")
                    | i <- [(1 :: Int) .. 100]
                    ]
                }
        fv = extractFeatures emptyFeatureContext req
    fQueryParamCount fv `shouldBe` 1.0

  it "extractFeatures: query param count below cap is normalized" $ do
    let req = (pathOnlyRequest "/")
                { queryString =
                    [ (BC.pack ("k" ++ show i), Just "v")
                    | i <- [(1 :: Int) .. 4]
                    ]
                }
        fv = extractFeatures emptyFeatureContext req
    fQueryParamCount fv `shouldBe` (4 / queryParamCountCap)

  it "extractFeatures: idempotent flag tracks the request method" $ do
    let getReq  = (headersOnlyRequest []) { requestMethod = "GET" }
        postReq = (headersOnlyRequest []) { requestMethod = "POST" }
    fMethodIdempotent (extractFeatures emptyFeatureContext getReq) `shouldBe` 1.0
    fMethodIdempotent (extractFeatures emptyFeatureContext postReq) `shouldBe` 0.0

  it "extractFeatures: geo signals reflect the FeatureContext" $ do
    let ctx = FeatureContext
                { fcGeoInfo = GeoInfo
                    { giCountryISO = Just "RU"
                    , giAsnNumber = Just 12345
                    , giAsnOrg = Just "ExampleNet"
                    , giFlaggedAsn = True
                    }
                , fcAsnConcentration = 0.75
                }
        fv = extractFeatures ctx (headersOnlyRequest [])
    fFlaggedAsn fv `shouldBe` 1.0
    fAsnConcentration fv `shouldBe` 0.75
    fCountryUnknown fv `shouldBe` 0.0

  it "extractFeatures: unknown country flag is set when geo is empty" $ do
    let fv = extractFeatures emptyFeatureContext (headersOnlyRequest [])
    fCountryUnknown fv `shouldBe` 1.0
    fFlaggedAsn fv `shouldBe` 0.0
    fAsnConcentration fv `shouldBe` 0.0

  it "extractFeatures: caps are reflected in named constants" $ do
    headerCountCap `shouldBe` 32.0
    pathDepthCap `shouldBe` 16.0
    queryParamCountCap `shouldBe` 32.0
    userAgentLengthCap `shouldBe` 256.0
    pathEntropyMax `shouldBe` 8.0
    acceptValueLengthCap `shouldBe` 200.0

  it "secFetchModeIsValid recognizes canonical fetch modes" $ do
    secFetchModeIsValid "navigate" `shouldBe` True
    secFetchModeIsValid "Cors" `shouldBe` True
    secFetchModeIsValid "no-cors" `shouldBe` True
    secFetchModeIsValid "same-origin" `shouldBe` True
    secFetchModeIsValid "websocket" `shouldBe` True
    secFetchModeIsValid "preflight" `shouldBe` False
    secFetchModeIsValid "" `shouldBe` False

  it "secFetchTripleIsCoherent accepts a top-level navigation triple" $
    secFetchTripleIsCoherent (Just "none") (Just "navigate") (Just "document")
      `shouldBe` True

  it "secFetchTripleIsCoherent accepts a same-origin XHR triple" $
    secFetchTripleIsCoherent (Just "same-origin") (Just "cors") (Just "empty")
      `shouldBe` True

  it "secFetchTripleIsCoherent rejects site=none with mode=cors" $
    secFetchTripleIsCoherent (Just "none") (Just "cors") (Just "empty")
      `shouldBe` False

  it "secFetchTripleIsCoherent rejects mode=navigate with non-document dest" $
    secFetchTripleIsCoherent (Just "same-origin") (Just "navigate") (Just "image")
      `shouldBe` False

  it "secFetchTripleIsCoherent rejects when any header is missing" $ do
    secFetchTripleIsCoherent Nothing (Just "navigate") (Just "document")
      `shouldBe` False
    secFetchTripleIsCoherent (Just "none") Nothing (Just "document")
      `shouldBe` False
    secFetchTripleIsCoherent (Just "none") (Just "navigate") Nothing
      `shouldBe` False

  it "uaPlatformConsistency returns 1 when no platform header is sent" $
    uaPlatformConsistency (Just "Mozilla/5.0 (Windows NT 10.0)") Nothing
      `shouldBe` 1.0

  it "uaPlatformConsistency returns 1 when CH-UA-Platform matches the UA" $ do
    uaPlatformConsistency
      (Just "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
      (Just "\"Windows\"")
      `shouldBe` 1.0
    uaPlatformConsistency
      (Just "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)")
      (Just "\"macOS\"")
      `shouldBe` 1.0

  it "uaPlatformConsistency returns 0 when CH-UA-Platform contradicts the UA" $
    uaPlatformConsistency
      (Just "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)")
      (Just "\"Windows\"")
      `shouldBe` 0.0

  it "uaPlatformConsistency returns 0 when UA is missing but platform is sent" $
    uaPlatformConsistency Nothing (Just "\"Windows\"") `shouldBe` 0.0

  it "acceptIsWildcard catches the bare-library default" $ do
    acceptIsWildcard (Just "*/*") `shouldBe` True
    acceptIsWildcard (Just " */* ") `shouldBe` True
    acceptIsWildcard (Just "text/html,*/*;q=0.8") `shouldBe` False
    acceptIsWildcard Nothing `shouldBe` False

  it "headerOrderIsCanonicalBrowser accepts a Chrome-style ordering" $ do
    let hs = [ ("host", "example.com")
             , ("user-agent", "Mozilla/5.0")
             , ("accept", "text/html")
             , ("accept-encoding", "gzip")
             , ("accept-language", "en-US")
             ]
    headerOrderIsCanonicalBrowser [(CI.mk k, v) | (k, v) <- hs] `shouldBe` True

  it "headerOrderIsCanonicalBrowser accepts a Firefox-style ordering" $ do
    let hs = [ ("host", "example.com")
             , ("user-agent", "Mozilla/5.0")
             , ("accept", "text/html")
             , ("accept-language", "en-US")
             , ("accept-encoding", "gzip")
             ]
    headerOrderIsCanonicalBrowser [(CI.mk k, v) | (k, v) <- hs] `shouldBe` True

  it "headerOrderIsCanonicalBrowser rejects a curl-style ordering" $ do
    let hs = [ ("host", "example.com")
             , ("accept", "*/*")
             , ("user-agent", "curl/8.4.0")
             ]
    headerOrderIsCanonicalBrowser [(CI.mk k, v) | (k, v) <- hs] `shouldBe` False

  it "headerOrderIsCanonicalBrowser tolerates extra headers in between" $ do
    let hs = [ ("host", "example.com")
             , ("connection", "keep-alive")
             , ("user-agent", "Mozilla/5.0")
             , ("upgrade-insecure-requests", "1")
             , ("accept", "text/html")
             , ("accept-encoding", "gzip")
             , ("accept-language", "en-US")
             ]
    headerOrderIsCanonicalBrowser [(CI.mk k, v) | (k, v) <- hs] `shouldBe` True

  it "extractFeatures: missing Sec-Fetch-Site flips the missing-site flag" $ do
    let fv = extractFeatures emptyFeatureContext (headersOnlyRequest [])
    fMissingSecFetchSite fv `shouldBe` 1.0
    fSecFetchModeValid fv `shouldBe` 0.0
    fSecFetchContextCoherent fv `shouldBe` 0.0

  it "extractFeatures: a coherent Sec-Fetch triple sets all three flags" $ do
    let fv = extractFeatures emptyFeatureContext
               (headersOnlyRequest
                  [ ("sec-fetch-site", "none")
                  , ("sec-fetch-mode", "navigate")
                  , ("sec-fetch-dest", "document")
                  ])
    fMissingSecFetchSite fv `shouldBe` 0.0
    fSecFetchModeValid fv `shouldBe` 1.0
    fSecFetchContextCoherent fv `shouldBe` 1.0

  it "extractFeatures: CH-UA-Platform consistency lights up for a real Chrome request" $ do
    let fv = extractFeatures emptyFeatureContext
               (headersOnlyRequest
                  [ ("user-agent",
                     "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
                  , ("sec-ch-ua-platform", "\"Windows\"")
                  ])
    fChUaPlatformPresent fv `shouldBe` 1.0
    fChUaPlatformConsistent fv `shouldBe` 1.0

  it "extractFeatures: CH-UA-Platform inconsistency on spoofed platform" $ do
    let fv = extractFeatures emptyFeatureContext
               (headersOnlyRequest
                  [ ("user-agent",
                     "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
                  , ("sec-ch-ua-platform", "\"Windows\"")
                  ])
    fChUaPlatformConsistent fv `shouldBe` 0.0

  it "extractFeatures: Accept */* trips the wildcard flag" $ do
    let fv = extractFeatures emptyFeatureContext
               (headersOnlyRequest [("accept", "*/*")])
    fAcceptIsWildcard fv `shouldBe` 1.0

  it "extractFeatures: a rich Accept value normalizes against the cap" $ do
    let v = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        fv = extractFeatures emptyFeatureContext
               (headersOnlyRequest [("accept", v)])
        expected = clamp01 (fromIntegral (BS.length v) / acceptValueLengthCap)
    fAcceptIsWildcard fv `shouldBe` 0.0
    fAcceptValueLength fv `shouldBe` expected

  it "extractFeatures: header_order_canonical lights up for browser-shaped requests" $ do
    let fv = extractFeatures emptyFeatureContext
               (headersOnlyRequest
                  [ ("host", "example.com")
                  , ("user-agent", "Mozilla/5.0")
                  , ("accept", "text/html")
                  , ("accept-encoding", "gzip")
                  , ("accept-language", "en-US")
                  ])
    fHeaderOrderCanonical fv `shouldBe` 1.0

  it "extractFeatures: header_order_canonical is 0 for curl-shaped requests" $ do
    let fv = extractFeatures emptyFeatureContext
               (headersOnlyRequest
                  [ ("host", "example.com")
                  , ("accept", "*/*")
                  , ("user-agent", "curl/8.4.0")
                  ])
    fHeaderOrderCanonical fv `shouldBe` 0.0

mlModelSpec :: Spec
mlModelSpec = describe "ML.Model" $ do
  it "exposes the leaf and noChild sentinels as -1" $ do
    leafSentinel `shouldBe` (-1)
    noChildIndex `shouldBe` (-1)
    defaultRootIndex `shouldBe` 0

  it "advertises a single supported ensemble version range" $ do
    minimumEnsembleVersion `shouldBe` 1
    maximumEnsembleVersion `shouldBe` 1
    currentEnsembleVersion `shouldBe` 1

  it "parseObjective accepts canonical aliases" $ do
    parseObjective "binary" `shouldBe` Right ObjectiveBinaryLogistic
    parseObjective "Binary_Logistic" `shouldBe` Right ObjectiveBinaryLogistic
    parseObjective "logistic" `shouldBe` Right ObjectiveBinaryLogistic
    parseObjective "regression" `shouldBe` Right ObjectiveRegression
    parseObjective "regression_l2" `shouldBe` Right ObjectiveRegression

  it "parseObjective rejects unknown strings" $
    parseObjective "softmax" `shouldSatisfy`
      (\r -> case r of { Left _ -> True; Right _ -> False })

  it "renderObjective round-trips for canonical names" $ do
    parseObjective (renderObjective ObjectiveBinaryLogistic)
      `shouldBe` Right ObjectiveBinaryLogistic
    parseObjective (renderObjective ObjectiveRegression)
      `shouldBe` Right ObjectiveRegression

  it "makeLeafTree builds a single-node leaf tree" $ do
    let t = makeLeafTree 0.42
    treeNodeCount t `shouldBe` 1
    nodeIsLeaf t 0 `shouldBe` True
    treeLeafValue t VU.! 0 `shouldBe` 0.42
    treeLeftChild t VU.! 0 `shouldBe` noChildIndex
    treeRightChild t VU.! 0 `shouldBe` noChildIndex

  it "makeStumpTree builds a 3-node split tree" $ do
    let t = makeStumpTree 5 0.5 (-1.0) 1.0
    treeNodeCount t `shouldBe` 3
    nodeIsLeaf t 0 `shouldBe` False
    nodeIsLeaf t 1 `shouldBe` True
    nodeIsLeaf t 2 `shouldBe` True
    treeFeatureIdx t VU.! 0 `shouldBe` 5
    treeThreshold t VU.! 0 `shouldBe` 0.5
    treeLeftChild t VU.! 0 `shouldBe` 1
    treeRightChild t VU.! 0 `shouldBe` 2
    treeLeafValue t VU.! 1 `shouldBe` (-1.0)
    treeLeafValue t VU.! 2 `shouldBe` 1.0

  it "validateTree accepts a leaf tree" $
    validateTree 20 (makeLeafTree 0.0) `shouldBe` Right ()

  it "validateTree accepts a stump tree" $
    validateTree 20 (makeStumpTree 3 0.25 (-0.7) 0.7) `shouldBe` Right ()

  it "validateTree rejects an empty tree" $ do
    let bad = Tree
                (VU.fromList [])
                (VU.fromList [])
                (VU.fromList [])
                (VU.fromList [])
                (VU.fromList [])
                (VU.fromList [])
                (VU.fromList [])
                (VU.fromList [])
    validateTree 20 bad `shouldSatisfy`
      (\r -> case r of { Left _ -> True; Right _ -> False })

  it "validateTree rejects mismatched SoA lengths" $ do
    let bad = Tree
                (VU.fromList [leafSentinel, leafSentinel])
                (VU.fromList [0.0])
                (VU.fromList [noChildIndex, noChildIndex])
                (VU.fromList [noChildIndex, noChildIndex])
                (VU.fromList [0.0, 0.0])
                (VU.fromList [0, 0])
                (VU.fromList [])
                (VU.fromList [])
    validateTree 20 bad `shouldSatisfy`
      (\r -> case r of { Left _ -> True; Right _ -> False })

  it "validateTree rejects out-of-range feature index" $ do
    let bad = makeStumpTree 99 0.5 (-1.0) 1.0
    validateTree 20 bad `shouldSatisfy`
      (\r -> case r of { Left _ -> True; Right _ -> False })

  it "validateTree rejects out-of-range left child" $ do
    let base = makeStumpTree 3 0.5 (-1.0) 1.0
        bad  = base { treeLeftChild = VU.fromList [99, noChildIndex, noChildIndex] }
    validateTree 20 bad `shouldSatisfy`
      (\r -> case r of { Left _ -> True; Right _ -> False })

  it "validateTree rejects self-referential split node" $ do
    let base = makeStumpTree 3 0.5 (-1.0) 1.0
        bad  = base { treeLeftChild = VU.fromList [0, noChildIndex, noChildIndex] }
    validateTree 20 bad `shouldSatisfy`
      (\r -> case r of { Left _ -> True; Right _ -> False })

  it "validateTree rejects a leaf with non-(-1) children" $ do
    let bad = (makeLeafTree 0.0) { treeLeftChild = VU.singleton 5 }
    validateTree 20 bad `shouldSatisfy`
      (\r -> case r of { Left _ -> True; Right _ -> False })

  it "validateTree rejects identical left and right children" $ do
    let base = makeStumpTree 3 0.5 (-1.0) 1.0
        bad  = base { treeRightChild = VU.fromList [1, noChildIndex, noChildIndex] }
    validateTree 20 bad `shouldSatisfy`
      (\r -> case r of { Left _ -> True; Right _ -> False })

  it "ensembleTreeCount counts the tree vector" $ do
    let ens = Ensemble currentEnsembleVersion 20 ObjectiveBinaryLogistic 0.0
                       defaultSigmoidScale False
                       (V.fromList [makeLeafTree 0.0, makeLeafTree 1.0])
    ensembleTreeCount ens `shouldBe` 2

  it "validateEnsemble accepts a minimal valid ensemble" $ do
    let ens = Ensemble currentEnsembleVersion 20 ObjectiveBinaryLogistic 0.0
                       defaultSigmoidScale False
                       (V.fromList [makeLeafTree 0.0])
    validateEnsemble 20 ens `shouldBe` Right ()

  it "validateEnsemble rejects an empty tree vector" $ do
    let ens = Ensemble currentEnsembleVersion 20 ObjectiveBinaryLogistic 0.0
                       defaultSigmoidScale False V.empty
    validateEnsemble 20 ens `shouldSatisfy`
      (\r -> case r of { Left _ -> True; Right _ -> False })

  it "validateEnsemble rejects a feature-count mismatch" $ do
    let ens = Ensemble currentEnsembleVersion 99 ObjectiveBinaryLogistic 0.0
                       defaultSigmoidScale False
                       (V.fromList [makeLeafTree 0.0])
    validateEnsemble 20 ens `shouldSatisfy`
      (\r -> case r of { Left _ -> True; Right _ -> False })

  it "validateEnsemble rejects an unsupported version" $ do
    let ens = Ensemble 99 20 ObjectiveBinaryLogistic 0.0
                       defaultSigmoidScale False
                       (V.fromList [makeLeafTree 0.0])
    validateEnsemble 20 ens `shouldSatisfy`
      (\r -> case r of { Left _ -> True; Right _ -> False })

  it "validateEnsemble propagates per-tree validation errors" $ do
    let badTree = makeStumpTree 99 0.5 (-1.0) 1.0
        ens = Ensemble currentEnsembleVersion 20 ObjectiveBinaryLogistic 0.0
                       defaultSigmoidScale False
                       (V.fromList [makeLeafTree 0.0, badTree])
    case validateEnsemble 20 ens of
      Left msg -> msg `shouldSatisfy` (\m -> "Tree 1" `isInfixOfStr` m)
      Right () -> error "expected Left"

  it "exposes default sigmoid scale of 1.0" $
    defaultSigmoidScale `shouldBe` 1.0

  it "decision-type bit constants match the LightGBM layout" $ do
    kCategoricalMask `shouldBe` (1 :: Int8)
    kDefaultLeftMask `shouldBe` (2 :: Int8)
    kMissingTypeShift `shouldBe` 2
    kMissingTypeMask `shouldBe` (12 :: Int8)

  it "makeDecisionType / decisionTypeBits round-trip for numerical splits" $ do
    let dt = makeDecisionType SplitNumerical True MissingTypeNaN
    decisionTypeBits dt `shouldBe` (SplitNumerical, True, MissingTypeNaN)

  it "makeDecisionType / decisionTypeBits round-trip for categorical splits" $ do
    let dt = makeDecisionType SplitCategorical False MissingTypeZero
    decisionTypeBits dt `shouldBe` (SplitCategorical, False, MissingTypeZero)

  it "splitKindFromDecisionType reads bit 0" $ do
    splitKindFromDecisionType 0 `shouldBe` SplitNumerical
    splitKindFromDecisionType 1 `shouldBe` SplitCategorical
    splitKindFromDecisionType 3 `shouldBe` SplitCategorical

  it "defaultLeftFromDecisionType reads bit 1" $ do
    defaultLeftFromDecisionType 0 `shouldBe` False
    defaultLeftFromDecisionType 2 `shouldBe` True
    defaultLeftFromDecisionType 3 `shouldBe` True

  it "missingTypeFromDecisionType reads bits 2-3" $ do
    missingTypeFromDecisionType 0 `shouldBe` MissingTypeNone
    missingTypeFromDecisionType 4 `shouldBe` MissingTypeZero
    missingTypeFromDecisionType 8 `shouldBe` MissingTypeNaN

  it "makeStumpTreeWithMissing encodes missing semantics in the root node" $ do
    let t = makeStumpTreeWithMissing 3 0.5 (-1.0) 1.0 False MissingTypeNaN
        dt = treeDecisionType t VU.! 0
    decisionTypeBits dt `shouldBe` (SplitNumerical, False, MissingTypeNaN)

  it "makeCategoricalStumpTree builds a categorical split with bitmap" $ do
    let bitmap = [1 :: Word32, 0, 4]
        t = makeCategoricalStumpTree 7 bitmap (-0.5) 0.5
        dt = treeDecisionType t VU.! 0
    treeNodeCount t `shouldBe` 3
    nodeIsLeaf t 0 `shouldBe` False
    treeFeatureIdx t VU.! 0 `shouldBe` 7
    splitKindFromDecisionType dt `shouldBe` SplitCategorical
    VU.toList (treeCatThreshold t) `shouldBe` bitmap
    VU.toList (treeCatBoundaries t) `shouldBe` [0, length bitmap]
    validateTree 20 t `shouldBe` Right ()

  it "validateTree rejects a categorical tree whose boundaries do not match the bitmap" $ do
    let base = makeCategoricalStumpTree 3 [1 :: Word32, 0] (-0.5) 0.5
        bad  = base { treeCatBoundaries = VU.fromList [0, 99] }
    validateTree 20 bad `shouldSatisfy`
      (\r -> case r of { Left _ -> True; Right _ -> False })

  it "validateTree rejects a categorical node whose threshold indexes outside cat_boundaries" $ do
    let base = makeCategoricalStumpTree 3 [1 :: Word32] (-0.5) 0.5
        bad  = base { treeThreshold = VU.fromList [99.0, 0.0, 0.0] }
    validateTree 20 bad `shouldSatisfy`
      (\r -> case r of { Left _ -> True; Right _ -> False })

netIpSpec :: Spec
netIpSpec = describe "Net.IP" $ do
  it "renders ipv4 sockaddr in dotted decimal" $
    sockAddrToIPBytes (ipv4Addr (10, 0, 0, 1) 1234) `shouldBe` "10.0.0.1"

  it "renders ipv4 loopback" $
    sockAddrToIPBytes (ipv4Addr (127, 0, 0, 1) 8080) `shouldBe` "127.0.0.1"

  it "renders unix sockaddr with prefix" $
    sockAddrToIPBytes (SockAddrUnix "/tmp/sock") `shouldBe` "unix:/tmp/sock"

  it "renders ipv6 sockaddr separated by colons (eight 16-bit groups)" $ do
    let addr = SockAddrInet6
          0
          0
          (tupleToHostAddress6 (0x2001, 0xdb8, 0, 0, 0, 0, 0, 1))
          0
        result = sockAddrToIPBytes addr
    BS.length result `shouldSatisfy` (> 0)
    BC.count ':' result `shouldBe` 7

mlLoaderModel :: T.Text
mlLoaderModel = T.unlines
  [ "tree"
  , "version=v4"
  , "num_class=1"
  , "num_tree_per_iteration=1"
  , "label_index=0"
  , "max_feature_idx=0"
  , "objective=binary sigmoid:1"
  , "feature_names=feat0"
  , "feature_infos=[0:1]"
  , ""
  , "Tree=0"
  , "num_leaves=1"
  , "num_cat=0"
  , "leaf_value=0.5"
  , "shrinkage=1"
  , ""
  , "end of trees"
  ]

mlLoaderModelBytes :: BS.ByteString
mlLoaderModelBytes = TE.encodeUtf8 mlLoaderModel

mlLoaderSubst :: T.Text -> T.Text -> BS.ByteString
mlLoaderSubst needle replacement =
  TE.encodeUtf8 (T.replace needle replacement mlLoaderModel)

parseFailsAt :: T.Text -> Either ParseError Ensemble -> Bool
parseFailsAt expectedKey (Left e) = peKey e == expectedKey
parseFailsAt _ _                  = False

parseSucceeds :: Either ParseError Ensemble -> Bool
parseSucceeds (Right _) = True
parseSucceeds _         = False

mlLoaderSpec :: Spec
mlLoaderSpec = describe "ML.Loader" $ do
  tinyBytes  <- runIO (BS.readFile "test/fixtures/ml/tiny_lgbm_v4.txt")
  stumpBytes <- runIO (BS.readFile "test/fixtures/ml/stump_lgbm_v4.txt")

  describe "happy path: tiny v4 fixture" $ do
    it "parses into a single-tree binary-logistic ensemble" $
      case parseEnsemble tinyBytes of
        Right ens -> do
          ensembleTreeCount ens     `shouldBe` 1
          ensembleFeatureCount ens  `shouldBe` 2
          ensembleObjective ens     `shouldBe` ObjectiveBinaryLogistic
          ensembleSigmoidScale ens  `shouldBe` 1.0
          ensembleAverageOutput ens `shouldBe` False
          ensembleVersion ens       `shouldBe` currentEnsembleVersion
          ensembleBaseScore ens     `shouldBe` 0.0
        Left err -> expectationFailure (show err)

    it "produces unified SoA with 2*num_leaves - 1 = 5 nodes" $
      case parseEnsemble tinyBytes of
        Right ens -> treeNodeCount (V.head (ensembleTrees ens)) `shouldBe` 5
        Left err  -> expectationFailure (show err)

    it "decodes negative children into unified leaf indices" $
      case parseEnsemble tinyBytes of
        Right ens -> do
          let tree = V.head (ensembleTrees ens)
          treeLeftChild  tree VU.! 0 `shouldBe` 1
          treeRightChild tree VU.! 0 `shouldBe` 4
          treeLeftChild  tree VU.! 1 `shouldBe` 2
          treeRightChild tree VU.! 1 `shouldBe` 3
        Left err -> expectationFailure (show err)

    it "marks unified leaf rows with leafSentinel and noChildIndex" $
      case parseEnsemble tinyBytes of
        Right ens -> do
          let tree = V.head (ensembleTrees ens)
          treeFeatureIdx tree VU.! 2 `shouldBe` leafSentinel
          treeFeatureIdx tree VU.! 3 `shouldBe` leafSentinel
          treeFeatureIdx tree VU.! 4 `shouldBe` leafSentinel
          treeLeftChild  tree VU.! 2 `shouldBe` noChildIndex
          treeRightChild tree VU.! 2 `shouldBe` noChildIndex
        Left err -> expectationFailure (show err)

    it "preserves leaf values at unified leaf indices" $
      case parseEnsemble tinyBytes of
        Right ens -> do
          let tree = V.head (ensembleTrees ens)
          treeLeafValue tree VU.! 2 `shouldBe`   0.3
          treeLeafValue tree VU.! 3 `shouldBe` (-0.2)
          treeLeafValue tree VU.! 4 `shouldBe` (-0.4)
        Left err -> expectationFailure (show err)

    it "preserves split feature indices and thresholds for internal nodes" $
      case parseEnsemble tinyBytes of
        Right ens -> do
          let tree = V.head (ensembleTrees ens)
          treeFeatureIdx tree VU.! 0 `shouldBe` 1
          treeFeatureIdx tree VU.! 1 `shouldBe` 0
          treeThreshold  tree VU.! 0 `shouldBe` 0.0
          treeThreshold  tree VU.! 1 `shouldBe` 5.0
        Left err -> expectationFailure (show err)

    it "encodes categorical bitmap with cat_boundaries" $
      case parseEnsemble tinyBytes of
        Right ens -> do
          let tree = V.head (ensembleTrees ens)
          VU.toList (treeCatBoundaries tree) `shouldBe` [0, 1]
          VU.toList (treeCatThreshold  tree) `shouldBe` [3]
        Left err -> expectationFailure (show err)

    it "tags categorical and numerical nodes via decision-type bits" $
      case parseEnsemble tinyBytes of
        Right ens -> do
          let tree = V.head (ensembleTrees ens)
          splitKindFromDecisionType (treeDecisionType tree VU.! 0)
            `shouldBe` SplitCategorical
          splitKindFromDecisionType (treeDecisionType tree VU.! 1)
            `shouldBe` SplitNumerical
        Left err -> expectationFailure (show err)

    it "ignores trailing feature_importances:, parameters:, pandas_categorical:" $
      parseEnsemble tinyBytes `shouldSatisfy` parseSucceeds

  describe "happy path: stump v4 fixture" $ do
    it "parses into a single-leaf tree with leafSentinel root" $
      case parseEnsemble stumpBytes of
        Right ens -> do
          ensembleTreeCount ens      `shouldBe` 1
          ensembleFeatureCount ens   `shouldBe` 1
          let tree = V.head (ensembleTrees ens)
          treeNodeCount tree         `shouldBe` 1
          treeLeafValue  tree VU.! 0 `shouldBe` 0.5
          treeFeatureIdx tree VU.! 0 `shouldBe` leafSentinel
          treeLeftChild  tree VU.! 0 `shouldBe` noChildIndex
          treeRightChild tree VU.! 0 `shouldBe` noChildIndex
        Left err -> expectationFailure (show err)

  describe "header rejection" $ do
    it "rejects empty input" $
      parseEnsemble BS.empty `shouldSatisfy` isLeft

    it "rejects when first non-blank line is not 'tree'" $
      parseEnsemble (TE.encodeUtf8 (T.replace "tree\n" "garbage\n" mlLoaderModel))
        `shouldSatisfy` isLeft

    it "rejects version=v3" $
      parseEnsemble (mlLoaderSubst "version=v4" "version=v3")
        `shouldSatisfy` parseFailsAt "version"

    it "rejects version=v5" $
      parseEnsemble (mlLoaderSubst "version=v4" "version=v5")
        `shouldSatisfy` parseFailsAt "version"

    it "rejects num_class=2 (multi-class)" $
      parseEnsemble (mlLoaderSubst "num_class=1" "num_class=2")
        `shouldSatisfy` parseFailsAt "num_class"

    it "rejects num_tree_per_iteration=2 (multi-class)" $
      parseEnsemble
        (mlLoaderSubst "num_tree_per_iteration=1" "num_tree_per_iteration=2")
        `shouldSatisfy` parseFailsAt "num_tree_per_iteration"

    it "rejects feature_names count not matching max_feature_idx+1" $
      parseEnsemble
        (TE.encodeUtf8
          (T.replace "feature_names=feat0" "feature_names=feat0 feat1" mlLoaderModel))
        `shouldSatisfy` parseFailsAt "feature_names"

    it "rejects unknown header keys" $
      parseEnsemble
        (TE.encodeUtf8
          (T.replace "feature_infos=[0:1]\n"
                     "feature_infos=[0:1]\nbogus_key=42\n" mlLoaderModel))
        `shouldSatisfy` isLeft

    it "rejects missing required header key (version)" $
      parseEnsemble (TE.encodeUtf8 (T.replace "version=v4\n" "" mlLoaderModel))
        `shouldSatisfy` parseFailsAt "version"

  describe "objective and sigmoid extraction" $ do
    it "parses sigmoid:0.5 from objective line" $
      case parseEnsemble (mlLoaderSubst "sigmoid:1" "sigmoid:0.5") of
        Right ens -> ensembleSigmoidScale ens `shouldBe` 0.5
        Left err  -> expectationFailure (show err)

    it "defaults objective to binary logistic when objective key absent" $
      case parseEnsemble
             (TE.encodeUtf8
               (T.replace "objective=binary sigmoid:1\n" "" mlLoaderModel)) of
        Right ens -> do
          ensembleObjective ens    `shouldBe` ObjectiveBinaryLogistic
          ensembleSigmoidScale ens `shouldBe` 1.0
        Left err -> expectationFailure (show err)

    it "rejects malformed sigmoid value" $
      parseEnsemble (mlLoaderSubst "sigmoid:1" "sigmoid:notanumber")
        `shouldSatisfy` parseFailsAt "objective"

    it "rejects unknown objective name" $
      parseEnsemble (mlLoaderSubst "objective=binary sigmoid:1" "objective=poisson")
        `shouldSatisfy` parseFailsAt "objective"

  describe "average_output bare key" $ do
    it "defaults to False when absent" $
      case parseEnsemble mlLoaderModelBytes of
        Right ens -> ensembleAverageOutput ens `shouldBe` False
        Left err  -> expectationFailure (show err)

    it "sets True when bare 'average_output' line present" $
      case parseEnsemble
             (TE.encodeUtf8
               (T.replace "feature_infos=[0:1]\n"
                          "feature_infos=[0:1]\naverage_output\n" mlLoaderModel)) of
        Right ens -> ensembleAverageOutput ens `shouldBe` True
        Left err  -> expectationFailure (show err)

  describe "tree-level rejection" $ do
    it "rejects is_linear=1 in any tree" $
      parseEnsemble
        (TE.encodeUtf8
          (T.replace "shrinkage=1\n" "is_linear=1\nshrinkage=1\n" mlLoaderModel))
        `shouldSatisfy` parseFailsAt "is_linear"

    it "rejects unknown tree keys" $
      parseEnsemble
        (TE.encodeUtf8
          (T.replace "leaf_value=0.5\n" "leaf_value=0.5\nbogus=1\n" mlLoaderModel))
        `shouldSatisfy` isLeft

    it "rejects num_leaves above maxNumLeaves" $
      parseEnsemble
        (TE.encodeUtf8 (T.replace "num_leaves=1" "num_leaves=999999" mlLoaderModel))
        `shouldSatisfy` parseFailsAt "num_leaves"

    it "rejects num_leaves of 0" $
      parseEnsemble
        (TE.encodeUtf8 (T.replace "num_leaves=1" "num_leaves=0" mlLoaderModel))
        `shouldSatisfy` parseFailsAt "num_leaves"

  describe "feature_names containing '='" $
    it "accepts feature_names with '=' in a name" $
      parseEnsemble
        (TE.encodeUtf8
          (T.replace "feature_names=feat0" "feature_names=foo=bar" mlLoaderModel))
        `shouldSatisfy` parseSucceeds

  describe "ParseError reporting" $ do
    it "reports correct 1-indexed line number for version error" $
      case parseEnsemble (mlLoaderSubst "version=v4" "version=v3") of
        Left err -> peLine err `shouldBe` 2
        Right _  -> expectationFailure "expected Left"

    it "reports the failing key name for version error" $
      case parseEnsemble (mlLoaderSubst "version=v4" "version=v3") of
        Left err -> peKey err `shouldBe` "version"
        Right _  -> expectationFailure "expected Left"

mkCatStump :: Bool -> MissingType -> [Word32] -> Double -> Double -> Tree
mkCatStump defaultLeft mtype bitmap leftV rightV =
  let bitmapVec  = VU.fromList bitmap
      boundaries = VU.fromList [0, VU.length bitmapVec]
      dt         = makeDecisionType SplitCategorical defaultLeft mtype
  in Tree
       { treeFeatureIdx    = VU.fromList [0, leafSentinel, leafSentinel]
       , treeThreshold     = VU.fromList [0.0, 0.0, 0.0]
       , treeLeftChild     = VU.fromList [1, noChildIndex, noChildIndex]
       , treeRightChild    = VU.fromList [2, noChildIndex, noChildIndex]
       , treeLeafValue     = VU.fromList [0.0, leftV, rightV]
       , treeDecisionType  = VU.fromList [dt, 0, 0]
       , treeCatBoundaries = boundaries
       , treeCatThreshold  = bitmapVec
       }

mkSingleFeatureEnsemble :: Objective -> Double -> Bool -> [Tree] -> Ensemble
mkSingleFeatureEnsemble obj sig avg trees = Ensemble
  { ensembleVersion       = currentEnsembleVersion
  , ensembleFeatureCount  = 1
  , ensembleObjective     = obj
  , ensembleBaseScore     = 0.0
  , ensembleSigmoidScale  = sig
  , ensembleAverageOutput = avg
  , ensembleTrees         = V.fromList trees
  }

binaryEnsemble :: [Tree] -> Ensemble
binaryEnsemble = mkSingleFeatureEnsemble ObjectiveBinaryLogistic defaultSigmoidScale False

singletonFv :: Double -> VU.Vector Double
singletonFv = VU.singleton

mlInferenceSpec :: Spec
mlInferenceSpec = describe "ML.Inference" $ do
  tinyBytes <- runIO (BS.readFile "test/fixtures/ml/tiny_lgbm_v4.txt")

  describe "walkTree on a leaf-only tree" $ do
    it "returns the root index for a stump tree" $
      walkTree (makeLeafTree 0.42) (singletonFv 0.0) `shouldBe` 0

    it "predictRaw returns the leaf value for a single-leaf single-tree ensemble" $
      predictRaw (binaryEnsemble [makeLeafTree 0.42]) (singletonFv 0.0)
        `shouldBe` 0.42

  describe "walkTree on a numerical stump (defaultLeft=True, MissingTypeNone)" $ do
    let tree   = makeStumpTreeWithMissing 0 0.5 (-1.0) 1.0 True MissingTypeNone
        ens    = binaryEnsemble [tree]

    it "fval below threshold goes left (leaf value -1.0)" $
      predictRaw ens (singletonFv 0.0) `shouldBe` (-1.0)

    it "fval above threshold goes right (leaf value 1.0)" $
      predictRaw ens (singletonFv 0.9) `shouldBe` 1.0

    it "fval exactly at threshold goes left (predicate is <=, not <)" $
      predictRaw ens (singletonFv 0.5) `shouldBe` (-1.0)

    it "NaN with MissingTypeNone is remapped to 0 then compared (0 <= 0.5 -> left)" $
      predictRaw ens (singletonFv (0.0 / 0.0)) `shouldBe` (-1.0)

  describe "MissingType=Zero routes via default-left flag" $ do
    let leftTree  = makeStumpTreeWithMissing 0 (-10.0) 7.0 (-7.0) True  MissingTypeZero
        rightTree = makeStumpTreeWithMissing 0 (-10.0) 7.0 (-7.0) False MissingTypeZero

    it "0.0 with defaultLeft=True hits left branch (ignoring threshold)" $
      predictRaw (binaryEnsemble [leftTree]) (singletonFv 0.0) `shouldBe` 7.0

    it "0.0 with defaultLeft=False hits right branch (ignoring threshold)" $
      predictRaw (binaryEnsemble [rightTree]) (singletonFv 0.0) `shouldBe` (-7.0)

    it "tiny non-zero (2e-36) is treated as zero by IsZero(kZeroThreshold=1e-35)" $
      predictRaw (binaryEnsemble [leftTree]) (singletonFv 2.0e-36)
        `shouldBe` 7.0

    it "value just above kZeroThreshold is NOT treated as zero" $
      predictRaw (binaryEnsemble [leftTree]) (singletonFv 1.0e-30)
        `shouldBe` (-7.0)

  describe "MissingType=NaN routes only when feature is NaN" $ do
    let nanTree = makeStumpTreeWithMissing 0 0.5 (-1.0) 1.0 True MissingTypeNaN

    it "NaN feature uses default-left (left leaf -1.0)" $
      predictRaw (binaryEnsemble [nanTree]) (singletonFv (0.0 / 0.0))
        `shouldBe` (-1.0)

    it "non-NaN feature still uses normal threshold comparison" $
      predictRaw (binaryEnsemble [nanTree]) (singletonFv 0.9)
        `shouldBe` 1.0

  describe "categorical bitmap routing" $ do
    let bitmap5 = [5 :: Word32]

    it "category 0 in bitmap 0b101 routes left" $
      predictRaw (binaryEnsemble [mkCatStump False MissingTypeNone bitmap5 (-2.0) 2.0])
                 (singletonFv 0.0)
        `shouldBe` (-2.0)

    it "category 1 NOT in bitmap 0b101 routes right" $
      predictRaw (binaryEnsemble [mkCatStump False MissingTypeNone bitmap5 (-2.0) 2.0])
                 (singletonFv 1.0)
        `shouldBe` 2.0

    it "category 2 in bitmap 0b101 routes left" $
      predictRaw (binaryEnsemble [mkCatStump False MissingTypeNone bitmap5 (-2.0) 2.0])
                 (singletonFv 2.0)
        `shouldBe` (-2.0)

    it "category beyond bitmap range routes right" $
      predictRaw (binaryEnsemble [mkCatStump False MissingTypeNone bitmap5 (-2.0) 2.0])
                 (singletonFv 99.0)
        `shouldBe` 2.0

    it "negative categorical feature routes right" $
      predictRaw (binaryEnsemble [mkCatStump False MissingTypeNone bitmap5 (-2.0) 2.0])
                 (singletonFv (-1.0))
        `shouldBe` 2.0

    it "categorical NaN with MissingTypeZero routes via default-left" $
      predictRaw (binaryEnsemble [mkCatStump True MissingTypeZero bitmap5 (-2.0) 2.0])
                 (singletonFv (0.0 / 0.0))
        `shouldBe` (-2.0)

  describe "multi-tree ensemble sums leaf contributions" $ do
    let t1 = makeStumpTreeWithMissing 0 0.0 (-0.3) 0.3 False MissingTypeNone
        t2 = makeStumpTreeWithMissing 0 0.5 (-0.2) 0.2 False MissingTypeNone

    it "sums each tree's chosen leaf value" $
      predictRaw (binaryEnsemble [t1, t2]) (singletonFv 0.7)
        `shouldBe` 0.5

    it "different feature value picks different leaves and changes the sum" $
      predictRaw (binaryEnsemble [t1, t2]) (singletonFv (-0.1))
        `shouldBe` (-0.5)

  describe "predictScore: average_output divisor" $ do
    let t1 = makeLeafTree 1.0
        t2 = makeLeafTree 3.0

    it "no average_output: predictScore equals predictRaw" $ do
      let ens = mkSingleFeatureEnsemble ObjectiveBinaryLogistic defaultSigmoidScale False [t1, t2]
      predictScore ens (singletonFv 0.0) `shouldBe` 4.0

    it "average_output=True divides raw by num_trees" $ do
      let ens = mkSingleFeatureEnsemble ObjectiveBinaryLogistic defaultSigmoidScale True [t1, t2]
      predictScore ens (singletonFv 0.0) `shouldBe` 2.0

    it "average_output=True with empty tree vector falls back to raw (n=0 guard)" $ do
      let ens = mkSingleFeatureEnsemble ObjectiveBinaryLogistic defaultSigmoidScale True []
      predictScore ens (singletonFv 0.0) `shouldBe` 0.0

  describe "sigmoidLink" $ do
    it "scale*x = 0 yields 0.5" $
      sigmoidLink 1.0 0.0 `shouldBe` 0.5

    it "very large positive x saturates near 1.0" $
      sigmoidLink 1.0 1000.0 `shouldBe` 1.0

    it "very large negative x saturates near 0.0" $
      sigmoidLink 1.0 (-1000.0) `shouldBe` 0.0

    it "scale=0.5 halves the steepness" $
      sigmoidLink 0.5 2.0 `shouldBe` (1.0 / (1.0 + exp (-1.0)))

  describe "predictProba: objective-specific link function" $ do
    it "binary logistic applies sigmoid with the ensemble's scale" $ do
      let ens = mkSingleFeatureEnsemble ObjectiveBinaryLogistic 1.0 False [makeLeafTree 0.0]
      predictProba ens (singletonFv 0.0) `shouldBe` 0.5

    it "binary logistic with sigmoidScale=0.5 applies the scale" $ do
      let ens = mkSingleFeatureEnsemble ObjectiveBinaryLogistic 0.5 False [makeLeafTree 2.0]
      predictProba ens (singletonFv 0.0) `shouldBe` (1.0 / (1.0 + exp (-1.0)))

    it "regression returns the score directly (no sigmoid)" $ do
      let ens = mkSingleFeatureEnsemble ObjectiveRegression 1.0 False [makeLeafTree 7.5]
      predictProba ens (singletonFv 0.0) `shouldBe` 7.5

  describe "kZeroThreshold matches LightGBM" $
    it "is exactly 1e-35" $
      kZeroThreshold `shouldBe` 1.0e-35

  describe "end-to-end against the tiny LightGBM v4 fixture" $ do
    case parseEnsemble tinyBytes of
      Left err -> it "parses tinyBytes" $ expectationFailure (show err)
      Right ens -> do
        it "feature vector [0, 0] (cat_feat=0 -> left, num_feat=0 -> left) hits leaf 0 (0.3)" $
          predictRaw ens (VU.fromList [0.0, 0.0]) `shouldBe` 0.3

        it "feature vector [10, 1] (cat_feat=1 -> left, num_feat=10 -> right) hits leaf 1 (-0.2)" $
          predictRaw ens (VU.fromList [10.0, 1.0]) `shouldBe` (-0.2)

        it "feature vector [0, 2] (cat_feat=2 -> right) hits leaf 2 (-0.4)" $
          predictRaw ens (VU.fromList [0.0, 2.0]) `shouldBe` (-0.4)

        it "predictProba on tinyBytes feeds the sum through binary sigmoid scale=1" $
          predictProba ens (VU.fromList [0.0, 0.0])
            `shouldBe` (1.0 / (1.0 + exp (-0.3)))

isPlatt :: Calibrator -> Bool
isPlatt (PlattCalibrator _ _) = True
isPlatt _                      = False

isIsotonic :: Calibrator -> Bool
isIsotonic (IsotonicCalibrator _) = True
isIsotonic _                       = False

mlCalibrationSpec :: Spec
mlCalibrationSpec = describe "ML.Calibration" $ do
  describe "NoCalibrator" $
    it "is identity for any input" $ do
      calibrate NoCalibrator 0.0 `shouldBe` 0.0
      calibrate NoCalibrator 0.5 `shouldBe` 0.5
      calibrate NoCalibrator 1.0 `shouldBe` 1.0
      calibrate NoCalibrator (-3.7) `shouldBe` (-3.7)

  describe "PlattCalibrator basic shape" $ do
    it "(a=0, b=0) yields constant 0.5 regardless of p" $ do
      calibrate (PlattCalibrator 0.0 0.0) 0.3    `shouldBe` 0.5
      calibrate (PlattCalibrator 0.0 0.0) 1000.0 `shouldBe` 0.5

    it "negative a produces output increasing in p" $ do
      let cal = PlattCalibrator (-2.0) 1.0
      calibrate cal 0.0 `shouldSatisfy` (< calibrate cal 1.0)

    it "positive (a*p + b) saturates near 0 for large p" $
      calibrate (PlattCalibrator 1.0 0.0) 1000.0 `shouldBe` 0.0

    it "negative (a*p + b) saturates near 1 for large p" $
      calibrate (PlattCalibrator (-1.0) 0.0) 1000.0 `shouldBe` 1.0

  describe "fitPlatt edge cases" $ do
    it "returns NoCalibrator for empty input" $
      fitPlatt VU.empty `shouldBe` NoCalibrator

    it "returns NoCalibrator for single sample" $
      fitPlatt (VU.singleton (0.5, True)) `shouldBe` NoCalibrator

    it "returns PlattCalibrator for >=2 samples" $
      fitPlatt (VU.fromList [(0.1, False), (0.9, True)])
        `shouldSatisfy` isPlatt

  describe "fitPlatt convergence on logistic-like data" $ do
    let negativeExamples = [(fromIntegral i / 100.0, False) | i <- [0  :: Int .. 49]]
        positiveExamples = [(fromIntegral i / 100.0, True)  | i <- [50 :: Int .. 99]]
        samples          = VU.fromList (negativeExamples ++ positiveExamples)
        cal              = fitPlatt samples

    it "fit recovers a < 0 (output increases with p)" $
      case cal of
        PlattCalibrator a _ -> a `shouldSatisfy` (< 0.0)
        _                    -> expectationFailure "expected PlattCalibrator"

    it "calibrated output at low p is less than at high p" $
      calibrate cal 0.1 `shouldSatisfy` (< calibrate cal 0.9)

    it "calibrated output stays in (0, 1)" $ do
      let mid = calibrate cal 0.5
      mid `shouldSatisfy` (> 0.0)
      mid `shouldSatisfy` (< 1.0)

  describe "fitIsotonic edge cases" $ do
    it "returns NoCalibrator for empty input" $
      fitIsotonic VU.empty `shouldBe` NoCalibrator

    it "returns NoCalibrator for single sample" $
      fitIsotonic (VU.singleton (0.5, True)) `shouldBe` NoCalibrator

    it "returns IsotonicCalibrator for >=2 samples" $
      fitIsotonic (VU.fromList [(0.1, False), (0.9, True)])
        `shouldSatisfy` isIsotonic

  describe "fitIsotonic on already-monotone data" $ do
    let samples = VU.fromList
          [(0.1, False), (0.3, False), (0.6, True), (0.9, True)]
        cal = fitIsotonic samples

    it "low raw clamps to 0.0" $
      calibrate cal 0.0 `shouldBe` 0.0

    it "high raw clamps to 1.0" $
      calibrate cal 1.0 `shouldBe` 1.0

    it "calibrated values are monotone non-decreasing" $
      case cal of
        IsotonicCalibrator bp ->
          let cals = VU.toList (VU.map snd bp)
          in all (uncurry (<=)) (zip cals (drop 1 cals)) `shouldBe` True
        _ -> expectationFailure "expected IsotonicCalibrator"

  describe "fitIsotonic corrects non-monotone data" $ do
    let samples = VU.fromList
          [(0.1, False), (0.4, True), (0.5, False), (0.9, True)]
        cal = fitIsotonic samples

    it "produces 3 breakpoints (one PAV merge)" $
      case cal of
        IsotonicCalibrator bp -> VU.length bp `shouldBe` 3
        _ -> expectationFailure "expected IsotonicCalibrator"

    it "calibrated values are monotone non-decreasing" $
      case cal of
        IsotonicCalibrator bp ->
          let cals = VU.toList (VU.map snd bp)
          in all (uncurry (<=)) (zip cals (drop 1 cals)) `shouldBe` True
        _ -> expectationFailure "expected IsotonicCalibrator"

  describe "fitIsotonic ties" $ do
    let samples = VU.fromList [(0.5, True), (0.5, False)]
        cal = fitIsotonic samples

    it "merges identical raw values into one breakpoint" $
      case cal of
        IsotonicCalibrator bp -> VU.length bp `shouldBe` 1
        _ -> expectationFailure "expected IsotonicCalibrator"

    it "merged breakpoint has averaged label" $
      calibrate cal 0.5 `shouldBe` 0.5

  describe "fitIsotonic with all-same labels" $ do
    it "all True calibrates to 1.0 across the range" $ do
      let cal = fitIsotonic (VU.fromList [(0.1, True), (0.5, True), (0.9, True)])
      calibrate cal 0.5 `shouldBe` 1.0

    it "all False calibrates to 0.0 across the range" $ do
      let cal = fitIsotonic (VU.fromList [(0.1, False), (0.5, False), (0.9, False)])
      calibrate cal 0.5 `shouldBe` 0.0

  describe "isotonic lookup behavior" $ do
    let cal = IsotonicCalibrator
                (VU.fromList [(0.25, 0.0), (0.5, 0.5), (0.75, 1.0)])

    it "clamps below first breakpoint" $
      calibrate cal 0.0 `shouldBe` 0.0

    it "clamps above last breakpoint" $
      calibrate cal 1.5 `shouldBe` 1.0

    it "returns exact value at a breakpoint" $
      calibrate cal 0.5 `shouldBe` 0.5

    it "linearly interpolates between breakpoints" $ do
      let bp = VU.fromList [(0.0, 0.25), (1.0, 0.75)]
      calibrate (IsotonicCalibrator bp) 0.5 `shouldBe` 0.5

    it "empty breakpoints pass through" $
      calibrate (IsotonicCalibrator VU.empty) 0.42 `shouldBe` 0.42

shouldBeApprox :: Double -> Double -> Expectation
shouldBeApprox actual expected =
  abs (actual - expected) `shouldSatisfy` (< 1.0e-9)

singleSplitTree :: Int -> Double -> Int -> Int -> ITree
singleSplitTree featIdx thr leftSize rightSize =
  ITreeSplit featIdx thr (ITreeLeaf leftSize) (ITreeLeaf rightSize)

mlIForestSpec :: Spec
mlIForestSpec = describe "ML.IForest" $ do
  describe "harmonicNumber" $ do
    it "H(0) is 0" $
      harmonicNumber 0 `shouldBe` 0.0

    it "H(1) is exactly 1.0" $
      harmonicNumber 1 `shouldBe` 1.0

    it "H(2) is exactly 1.5" $
      harmonicNumber 2 `shouldBe` 1.5

    it "H(3) is 1 + 1/2 + 1/3" $
      harmonicNumber 3 `shouldBeApprox` (1.0 + 0.5 + 1.0 / 3.0)

    it "H(1000) matches the asymptotic ln(n)+gamma+1/(2n) within 1e-6" $ do
      let expected = log 1000.0 + eulerMascheroni + 1.0 / (2.0 * 1000.0)
      abs (harmonicNumber 1000 - expected) `shouldSatisfy` (< 1.0e-6)

    it "rejects negative input by returning 0" $
      harmonicNumber (-5) `shouldBe` 0.0

  describe "normalizationConstant c(n)" $ do
    it "c(0) is 0 (degenerate)" $
      normalizationConstant 0 `shouldBe` 0.0

    it "c(1) is 0 (degenerate)" $
      normalizationConstant 1 `shouldBe` 0.0

    it "c(2) is 2*H(1) - 2*1/2 = 1.0" $
      normalizationConstant 2 `shouldBe` 1.0

    it "c(256) matches Liu et al. 2008 reference value" $
      normalizationConstant 256
        `shouldBeApprox`
          (2.0 * harmonicNumber 255 - 2.0 * 255.0 / 256.0)

  describe "pathLength on a single split" $ do
    let tree = singleSplitTree 0 0.5 1 1
        fvLeft  = VU.singleton 0.3
        fvRight = VU.singleton 0.7

    it "feature value <= threshold goes left, depth increments to 1" $
      pathLength tree fvLeft 0
        `shouldBe` (1.0 + normalizationConstant 1)

    it "feature value > threshold goes right, depth increments to 1" $
      pathLength tree fvRight 0
        `shouldBe` (1.0 + normalizationConstant 1)

    it "leaf adds c(leafSize) to currentDepth" $ do
      let leaf10 = ITreeLeaf 10
      pathLength leaf10 (VU.singleton 0.0) 5
        `shouldBe` (5.0 + normalizationConstant 10)

  describe "pathLength on a deeper tree" $ do
    let tree = ITreeSplit 0 0.5
                 (ITreeSplit 1 0.5
                   (ITreeLeaf 1) (ITreeLeaf 1))
                 (ITreeLeaf 2)
        fv00 = VU.fromList [0.3, 0.3]
        fv01 = VU.fromList [0.3, 0.7]
        fv1  = VU.fromList [0.7, 0.0]

    it "fv00 traverses two splits and lands on left-left leaf" $
      pathLength tree fv00 0
        `shouldBe` (2.0 + normalizationConstant 1)

    it "fv01 traverses two splits and lands on left-right leaf" $
      pathLength tree fv01 0
        `shouldBe` (2.0 + normalizationConstant 1)

    it "fv1 traverses one split and lands on right leaf with size 2" $
      pathLength tree fv1 0
        `shouldBe` (1.0 + normalizationConstant 2)

  describe "scoreIForest edge cases" $ do
    it "empty forest returns 0.0" $
      scoreIForest (IForest V.empty 256) (VU.singleton 0.0) `shouldBe` 0.0

    it "subsample size 0 returns 0.0" $
      scoreIForest (IForest (V.singleton (ITreeLeaf 1)) 0) (VU.singleton 0.0)
        `shouldBe` 0.0

    it "subsample size 1 returns 0.0 (c(1) is 0)" $
      scoreIForest (IForest (V.singleton (ITreeLeaf 1)) 1) (VU.singleton 0.0)
        `shouldBe` 0.0

  describe "scoreIForest produces values in (0, 1]" $ do
    let forest = IForest
          (V.fromList
            [ singleSplitTree 0 0.5 1 1
            , singleSplitTree 0 0.7 1 1
            , singleSplitTree 0 0.3 1 1
            ])
          4

    it "anomalous input produces a score" $ do
      let s = scoreIForest forest (VU.singleton 0.0)
      s `shouldSatisfy` (> 0.0)
      s `shouldSatisfy` (<= 1.0)

  describe "scoreIForest: shorter average path = higher anomaly score" $ do
    let shallow = IForest
          (V.singleton (ITreeSplit 0 0.5 (ITreeLeaf 1) (ITreeLeaf 1)))
          16
        deep    = IForest
          (V.singleton
            (ITreeSplit 0 0.5
              (ITreeSplit 1 0.5
                (ITreeSplit 2 0.5 (ITreeLeaf 1) (ITreeLeaf 1))
                (ITreeLeaf 1))
              (ITreeLeaf 1)))
          16
        fv = VU.fromList [0.3, 0.3, 0.3]

    it "shallow tree (depth 1) yields higher score than deep tree (depth 3)" $
      scoreIForest shallow fv `shouldSatisfy` (> scoreIForest deep fv)

  describe "default constants from Liu et al. 2008" $ do
    it "default tree count is 100" $
      defaultIForestNumTrees `shouldBe` 100

    it "default subsample size is 256" $
      defaultIForestSubsampleSize `shouldBe` 256

    it "Euler-Mascheroni constant matches the standard 16-digit value" $
      eulerMascheroni `shouldBe` 0.5772156649015329

mlEngineSpec :: Spec
mlEngineSpec = describe "ML.Engine" $ do
  let humanLeafEnsemble = binaryEnsemble [makeLeafTree (-5.0)]
      botLeafEnsemble   = binaryEnsemble [makeLeafTree   5.0]
      midLeafEnsemble   = binaryEnsemble [makeLeafTree   0.0]

      cfg               = defaultEngineConfig
      eng e cal mIf     = makeEngine e cal mIf cfg

      lowAnomalyForest  = IForest (V.singleton (ITreeLeaf 256)) 256
      highAnomalyForest = IForest (V.singleton (ITreeLeaf 1))   256

  describe "defaultEngineConfig" $ do
    it "uses sensible defaults" $ do
      ecHumanThreshold       cfg `shouldBe` 0.3
      ecBotThreshold         cfg `shouldBe` 0.7
      ecIForestEscalation    cfg `shouldBe` 0.6
      ecChallengeOnAmbiguous cfg `shouldBe` True

  describe "decision boundaries with NoCalibrator and no IForest" $ do
    it "very negative leaf (proba ~ 0.0067) routes to DecisionHuman" $
      runEngineDecision (eng humanLeafEnsemble NoCalibrator Nothing) (singletonFv 0.0)
        `shouldBe` DecisionHuman

    it "very positive leaf (proba ~ 0.993) routes to DecisionBot" $
      runEngineDecision (eng botLeafEnsemble NoCalibrator Nothing) (singletonFv 0.0)
        `shouldBe` DecisionBot

    it "midpoint leaf (proba = 0.5) lands in ambiguous band -> DecisionChallenge" $
      runEngineDecision (eng midLeafEnsemble NoCalibrator Nothing) (singletonFv 0.0)
        `shouldBe` DecisionChallenge

  describe "ambiguous band escalation via IForest" $ do
    it "low-anomaly IForest (score 0.5 < 0.6 escalation) keeps DecisionChallenge" $
      runEngineDecision
        (eng midLeafEnsemble NoCalibrator (Just lowAnomalyForest))
        (singletonFv 0.0)
        `shouldBe` DecisionChallenge

    it "high-anomaly IForest (score 1.0 >= 0.6 escalation) escalates to DecisionBot" $
      runEngineDecision
        (eng midLeafEnsemble NoCalibrator (Just highAnomalyForest))
        (singletonFv 0.0)
        `shouldBe` DecisionBot

    it "DecisionDetails records the IF score when present" $
      ddIForestScore
        (runEngine (eng midLeafEnsemble NoCalibrator (Just highAnomalyForest))
                   (singletonFv 0.0))
        `shouldBe` Just 1.0

    it "DecisionDetails records Nothing for IF score when absent" $
      ddIForestScore
        (runEngine (eng midLeafEnsemble NoCalibrator Nothing) (singletonFv 0.0))
        `shouldBe` Nothing

  describe "ambiguous band with challenges disabled" $ do
    let noChallengeCfg = cfg { ecChallengeOnAmbiguous = False }
        engNoChal e cal mIf = makeEngine e cal mIf noChallengeCfg

    it "ambiguous calibrated + no IForest falls through to DecisionHuman" $
      runEngineDecision
        (engNoChal midLeafEnsemble NoCalibrator Nothing)
        (singletonFv 0.0)
        `shouldBe` DecisionHuman

    it "ambiguous calibrated + low-anomaly IForest still falls through to DecisionHuman" $
      runEngineDecision
        (engNoChal midLeafEnsemble NoCalibrator (Just lowAnomalyForest))
        (singletonFv 0.0)
        `shouldBe` DecisionHuman

    it "ambiguous calibrated + high-anomaly IForest escalates to DecisionBot" $
      runEngineDecision
        (engNoChal midLeafEnsemble NoCalibrator (Just highAnomalyForest))
        (singletonFv 0.0)
        `shouldBe` DecisionBot

  describe "calibrator changes the decision threshold" $ do
    let almostBotEnsemble = binaryEnsemble [makeLeafTree 1.5]
        rawProba          = 1.0 / (1.0 + exp (-1.5))

    it "without calibration, raw proba in (0.7, 0.99) -> DecisionBot" $ do
      let result = runEngine (eng almostBotEnsemble NoCalibrator Nothing) (singletonFv 0.0)
      ddRawProba   result `shouldBe` rawProba
      ddCalibrated result `shouldBe` rawProba
      ddDecision   result `shouldBe` DecisionBot

    it "Platt with strongly negative a*p+b pulls calibrated below human threshold" $ do
      let cal    = PlattCalibrator (-100.0) 100.0
          result = runEngine (eng almostBotEnsemble cal Nothing) (singletonFv 0.0)
      ddCalibrated result `shouldSatisfy` (< 0.3)
      ddDecision   result `shouldBe` DecisionHuman

  describe "DecisionDetails mirrors all four fields" $ do
    let result = runEngine (eng midLeafEnsemble NoCalibrator Nothing) (singletonFv 0.0)
    it "ddDecision reflects the routing" $
      ddDecision result `shouldBe` DecisionChallenge
    it "ddRawProba is predictProba output (0.5 for leaf=0)" $
      ddRawProba result `shouldBe` 0.5
    it "ddCalibrated equals ddRawProba under NoCalibrator" $
      ddCalibrated result `shouldBe` 0.5
    it "ddIForestScore is Nothing when no IForest configured" $
      ddIForestScore result `shouldBe` Nothing

mlEngineWithLeaf :: Double -> Engine
mlEngineWithLeaf leafValue =
  let ens = Ensemble
        { ensembleVersion       = currentEnsembleVersion
        , ensembleFeatureCount  = featureVectorLength
        , ensembleObjective     = ObjectiveBinaryLogistic
        , ensembleBaseScore     = 0.0
        , ensembleSigmoidScale  = defaultSigmoidScale
        , ensembleAverageOutput = False
        , ensembleTrees         = V.singleton (makeLeafTree leafValue)
        }
  in makeEngine ens NoCalibrator Nothing defaultEngineConfig

mlMiddlewareSpec :: Spec
mlMiddlewareSpec = describe "ML.Middleware" $ do
  let humanEng     = mlEngineWithLeaf (-5.0)
      botEng       = mlEngineWithLeaf   5.0
      challengeEng = mlEngineWithLeaf   0.0
      ctx          = emptyFeatureContext
      humanCfg     = defaultMLMiddlewareConfig humanEng     ctx
      botCfg       = defaultMLMiddlewareConfig botEng       ctx
      challengeCfg = defaultMLMiddlewareConfig challengeEng ctx
      buildApp cfg = mlBotDetectionMiddleware cfg okApp

  describe "DecisionHuman → pass through with ML signal headers" $ do
    it "returns 200 from inner application" $ do
      resp <- runSession (request Network.Wai.Test.defaultRequest) (buildApp humanCfg)
      simpleStatus resp `shouldBe` status200

    it "attaches X-Aenebris-ML-Decision: human" $ do
      resp <- runSession (request Network.Wai.Test.defaultRequest) (buildApp humanCfg)
      lookup decisionResponseHeader (simpleHeaders resp)
        `shouldBe` Just (decisionToWireText DecisionHuman)

    it "attaches X-Aenebris-ML-Score header" $ do
      resp <- runSession (request Network.Wai.Test.defaultRequest) (buildApp humanCfg)
      lookup scoreResponseHeader (simpleHeaders resp) `shouldSatisfy` isJust

    it "omits ML signal headers when mmcAttachHeaders=False" $ do
      let cfg  = humanCfg { mmcAttachHeaders = False }
          app  = buildApp cfg
      resp <- runSession (request Network.Wai.Test.defaultRequest) app
      lookup decisionResponseHeader (simpleHeaders resp) `shouldBe` Nothing
      lookup scoreResponseHeader    (simpleHeaders resp) `shouldBe` Nothing

  describe "DecisionBot → 403 block" $ do
    it "returns 403" $ do
      resp <- runSession (request Network.Wai.Test.defaultRequest) (buildApp botCfg)
      simpleStatus resp `shouldBe` status403

    it "attaches X-Aenebris-ML-Decision: bot" $ do
      resp <- runSession (request Network.Wai.Test.defaultRequest) (buildApp botCfg)
      lookup decisionResponseHeader (simpleHeaders resp)
        `shouldBe` Just (decisionToWireText DecisionBot)

    it "responds with text/plain content type" $ do
      resp <- runSession (request Network.Wai.Test.defaultRequest) (buildApp botCfg)
      lookup "Content-Type" (simpleHeaders resp)
        `shouldSatisfy` maybe False (BS.isPrefixOf "text/plain")

  describe "DecisionChallenge → 403 challenge page" $ do
    it "returns 403" $ do
      resp <- runSession (request Network.Wai.Test.defaultRequest) (buildApp challengeCfg)
      simpleStatus resp `shouldBe` status403

    it "attaches X-Aenebris-ML-Decision: challenge" $ do
      resp <- runSession (request Network.Wai.Test.defaultRequest) (buildApp challengeCfg)
      lookup decisionResponseHeader (simpleHeaders resp)
        `shouldBe` Just (decisionToWireText DecisionChallenge)

    it "responds with text/html content type" $ do
      resp <- runSession (request Network.Wai.Test.defaultRequest) (buildApp challengeCfg)
      lookup "Content-Type" (simpleHeaders resp)
        `shouldSatisfy` maybe False (BS.isPrefixOf "text/html")

  describe "custom response builders override defaults" $
    it "custom mmcBotResponse is used instead of the default 403" $ do
      let customBotResp _req _details =
            responseLBS status429
              [("Content-Type", "text/plain")]
              "custom bot response"
          cfg = botCfg { mmcBotResponse = customBotResp }
      resp <- runSession (request Network.Wai.Test.defaultRequest) (buildApp cfg)
      simpleStatus resp `shouldBe` status429

  describe "logging callback fires" $
    it "mmcLogDetails callback is invoked once per request" $ do
      counter <- newTVarIO (0 :: Int)
      let logCallback _req _details =
            atomically (modifyTVar' counter (+ 1))
          cfg = humanCfg { mmcLogDetails = Just logCallback }
      _ <- runSession (request Network.Wai.Test.defaultRequest) (buildApp cfg)
      readTVarIO counter `shouldReturn` 1

headersOnlyRequest :: [(BS.ByteString, BS.ByteString)] -> Request
headersOnlyRequest hs =
  Network.Wai.Test.defaultRequest
    { requestHeaders = [(CI.mk k, v) | (k, v) <- hs]
    , requestMethod = "GET"
    }

pathOnlyRequest :: BS.ByteString -> Request
pathOnlyRequest = setPath (headersOnlyRequest [])

isLeftWith :: String -> Either String () -> Bool
isLeftWith needle (Left msg) = needle `isInfixOfStr` msg
isLeftWith _ _ = False

isInfixOfStr :: String -> String -> Bool
isInfixOfStr needle hay
  | length needle > length hay = False
  | otherwise = any (\i -> take (length needle) (drop i hay) == needle) [0 .. length hay - length needle]
