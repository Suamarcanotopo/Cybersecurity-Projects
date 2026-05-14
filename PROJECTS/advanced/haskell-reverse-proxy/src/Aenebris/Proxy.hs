{-
©AngelaMos | 2026
Proxy.hs
-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Aenebris.Proxy
  ( ProxyState(..)
  , initProxyState
  , startProxy
  , proxyApp
  , selectUpstream
  ) where

import Aenebris.Backend
import Aenebris.Config
import Aenebris.Connection
  ( ConnectionType(..)
  , defaultTimeoutConfig
  , detectConnectionType
  , microsPerSecond
  , tcUpstreamReadSeconds
  )
import Aenebris.HealthCheck
import Aenebris.LoadBalancer
import Aenebris.TLS
import Aenebris.Tunnel
import Aenebris.Middleware.Security
import Aenebris.Middleware.Redirect
import Aenebris.RateLimit
  ( RateLimiter
  , createRateLimiter
  , parseRateSpec
  , rateLimitMiddleware
  )
import Aenebris.DDoS.EarlyData (earlyDataGuard)
import Aenebris.DDoS.MemoryShed
  ( MemoryShed
  , MemoryShedConfig(..)
  , defaultHighWaterFraction
  , memoryShedMiddleware
  , newMemoryShed
  , startMemoryShedPoller
  )
import Aenebris.DDoS.IPJail
  ( IPJail
  , defaultIPJailConfig
  , ipJailMiddleware
  , newIPJail
  , startJailSweeper
  )
import Aenebris.DDoS.ConnLimit
  ( ConnLimiter
  , ConnLimitConfig(..)
  , connLimitOnClose
  , connLimitOnOpen
  , newConnLimiter
  )
import Aenebris.Fingerprint.JA4H (ja4hMiddleware)
import Aenebris.WAF.Engine (wafMiddleware)
import Aenebris.WAF.Patterns (defaultRuleSet)
import Aenebris.WAF.Rule (RuleSet)
import Aenebris.Honeypot
  ( HoneypotConfig(..)
  , buildHoneypotConfig
  , honeypotMiddleware
  )
import Aenebris.Geo
  ( Geo
  , buildGeoConfig
  , geoConfig
  , gcCountryDb
  , gcAsnDb
  , gcFlaggedAsns
  , gcBlockedCountries
  , openGeo
  , startAsnSweeper
  , geoMiddleware
  )
import Control.Concurrent.STM (TVar, newTVarIO)
import Control.Concurrent.Async (Async, async, waitAnyCancel)
import Control.Exception (SomeException, try)
import Control.Monad (unless, zipWithM)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import Data.ByteString.Builder (byteString)
import qualified Data.ByteString.Lazy as LBS
import Data.Function ((&))
import Data.List (sortBy)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Ord (comparing)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Client
  ( Manager
  , RequestBody(..)
  , brRead
  , parseRequest
  , withResponse
  )
import qualified Network.HTTP.Client as HTTP
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Handler.Warp
  ( Settings
  , defaultSettings
  , runSettings
  , setMaxTotalHeaderLength
  , setOnClose
  , setOnOpen
  , setPort
  , setTimeout
  )
import Network.Wai.Handler.WarpTLS (runTLS)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import System.Timeout (timeout)

memoryShedPollIntervalMicros :: Int
memoryShedPollIntervalMicros = microsPerSecond

contentTypePlain :: ByteString
contentTypePlain = "text/plain"

bodyNotFound :: LBS.ByteString
bodyNotFound = "Not Found: No route configured for this host/path"

bodyUpstreamMisconfigured :: LBS.ByteString
bodyUpstreamMisconfigured = "Internal Server Error: Upstream configuration error"

bodyNoHealthyBackends :: LBS.ByteString
bodyNoHealthyBackends = "Service Unavailable: No healthy backends available"

bodyBadGateway :: LBS.ByteString
bodyBadGateway = "Bad Gateway: Could not connect to backend server"

bodyGatewayTimeout :: LBS.ByteString
bodyGatewayTimeout = "504 Gateway Timeout: upstream did not respond in time"

bodyWebSocketUpgradeFailed :: LBS.ByteString
bodyWebSocketUpgradeFailed = "WebSocket upgrade failed"

hopByHopRequestHeaders :: [HeaderName]
hopByHopRequestHeaders =
  [ "Connection"
  , "Keep-Alive"
  , "Proxy-Authenticate"
  , "Proxy-Authorization"
  , "TE"
  , "Trailers"
  , "Transfer-Encoding"
  , "Upgrade"
  ]

hopByHopResponseHeaders :: [HeaderName]
hopByHopResponseHeaders =
  [ "Transfer-Encoding"
  , "Connection"
  , "Keep-Alive"
  ]

eventStreamContentType :: ByteString
eventStreamContentType = "text/event-stream"

chunkedEncoding :: ByteString
chunkedEncoding = "chunked"

httpScheme :: String
httpScheme = "http://"

data ProxyState = ProxyState
  { psConfig         :: !Config
  , psLoadBalancers  :: !(Map Text LoadBalancer)
  , psHealthCheckers :: ![Async ()]
  , psManager        :: !Manager
  , psRateLimiter    :: !(Maybe RateLimiter)
  , psMemoryShed     :: !(Maybe MemoryShed)
  , psIPJail         :: !(Maybe IPJail)
  , psConnLimiter    :: !(Maybe ConnLimiter)
  , psWafRuleSet     :: !(TVar RuleSet)
  , psGeo            :: !(Maybe Geo)
  }

initProxyState :: Config -> Manager -> IO ProxyState
initProxyState config manager = do
  lbs <- mapM createUpstreamLoadBalancer (configUpstreams config)
  let lbMap = Map.fromList (zip (map upstreamName (configUpstreams config)) lbs)

  checkers <- mapM startUpstreamHealthChecker (configUpstreams config)

  rateLimiter <- case configRateLimit config >>= parseRateSpec of
    Just spec -> Just <$> createRateLimiter spec
    Nothing -> pure Nothing

  let ddos = configDDoS config

  memShed <- case ddos >>= ddosMemoryShedBytes of
    Just budgetBytes -> do
      ms <- newMemoryShed
      let cfg = MemoryShedConfig
            { mscHeapBudgetBytes = fromInteger budgetBytes
            , mscHighWaterFraction = fromMaybe defaultHighWaterFraction
                (ddos >>= ddosMemoryShedHighWater)
            , mscPollIntervalMicros = memoryShedPollIntervalMicros
            }
      _ <- startMemoryShedPoller cfg ms
      pure (Just ms)
    Nothing -> pure Nothing

  ipJail <- case ddos >>= ddosJailCooldownSeconds of
    Just _ -> do
      j <- newIPJail
      _ <- startJailSweeper defaultIPJailConfig j
      pure (Just j)
    Nothing -> pure Nothing

  connLimiter <- case ddos >>= ddosPerIPConnections of
    Just n -> Just <$> newConnLimiter (ConnLimitConfig n)
    Nothing -> pure Nothing

  wafVar <- newTVarIO defaultRuleSet

  geoHandle <- case buildGeoConfig (configGeo config) of
    Just gcfg -> do
      g <- openGeo gcfg
      _ <- startAsnSweeper g
      pure (Just g)
    Nothing -> pure Nothing

  return ProxyState
    { psConfig         = config
    , psLoadBalancers  = lbMap
    , psHealthCheckers = checkers
    , psManager        = manager
    , psRateLimiter    = rateLimiter
    , psMemoryShed     = memShed
    , psIPJail         = ipJail
    , psConnLimiter    = connLimiter
    , psWafRuleSet     = wafVar
    , psGeo            = geoHandle
    }
  where
    createUpstreamLoadBalancer :: Upstream -> IO LoadBalancer
    createUpstreamLoadBalancer upstream = do
      backends <- zipWithM createRuntimeBackend [0..] (upstreamServers upstream)
      let weights = map serverWeight (upstreamServers upstream)
          strategy = case weights of
            [] -> RoundRobin
            (w:ws)
              | all (== w) ws -> RoundRobin
              | otherwise     -> WeightedRoundRobin
      createLoadBalancer strategy backends

    startUpstreamHealthChecker :: Upstream -> IO (Async ())
    startUpstreamHealthChecker upstream = do
      backends <- zipWithM createRuntimeBackend [0..] (upstreamServers upstream)
      let hcConfig = case upstreamHealthCheck upstream of
            Just hc -> defaultHealthCheckConfig
              { hcEndpoint = healthCheckPath hc
              }
            Nothing -> defaultHealthCheckConfig
      startHealthChecker manager hcConfig backends

startProxy :: ProxyState -> IO ()
startProxy ProxyState{..} = do
  putStrLn "Starting Aenebris reverse proxy"
  putStrLn $ "Loaded " ++ show (length (configUpstreams psConfig)) ++ " upstream(s)"
  putStrLn $ "Loaded " ++ show (length (configRoutes psConfig)) ++ " route(s)"
  putStrLn "Health checking enabled for all upstreams"

  case configListen psConfig of
    [] -> do
      hPutStrLn stderr "ERROR: No listen ports configured"
      exitFailure
    listenConfigs -> do
      case psRateLimiter of
        Just _  -> putStrLn "Rate limiting enabled"
        Nothing -> pure ()

      putStrLn "WAF enabled (Phase 1: paranoia level 2, default rule pack)"
      case buildHoneypotConfig (configHoneypot psConfig) of
        Just hp -> putStrLn $
          "Honeypot enabled ("
            ++ show (length (hpPatterns hp))
            ++ " trap patterns, action="
            ++ show (hpAction hp)
            ++ ")"
        Nothing -> pure ()
      case psGeo of
        Just g ->
          let gc = geoConfig g
              parts =
                [ "country_db=" ++ maybe "off" (const "on") (gcCountryDb gc)
                , "asn_db=" ++ maybe "off" (const "on") (gcAsnDb gc)
                , "blocked=" ++ show (length (gcBlockedCountries gc))
                , "flagged_asns=" ++ show (length (gcFlaggedAsns gc))
                ]
          in putStrLn $ "Geo/ASN enabled (" ++ unwords parts ++ ")"
        Nothing -> pure ()

      servers <- mapM
        (launchServer psConfig psLoadBalancers psManager
                      psRateLimiter psMemoryShed psIPJail
                      psConnLimiter psWafRuleSet psGeo)
        listenConfigs

      _ <- waitAnyCancel servers
      putStrLn "All servers stopped"

launchServer
  :: Config
  -> Map Text LoadBalancer
  -> Manager
  -> Maybe RateLimiter
  -> Maybe MemoryShed
  -> Maybe IPJail
  -> Maybe ConnLimiter
  -> TVar RuleSet
  -> Maybe Geo
  -> ListenConfig
  -> IO (Async ())
launchServer config loadBalancers manager mRateLimiter mMemShed mIPJail mConnLim wafVar mGeo listenConfig =
  async $ do
    let port = listenPort listenConfig
        shouldRedirect = fromMaybe False (listenRedirectHTTPS listenConfig)
        ddosCfg = fromMaybe defaultDDoSConfig (configDDoS config)

        baseApp          = proxyApp config loadBalancers manager
        fingerprintedApp = ja4hMiddleware baseApp
        wafApp           = wafMiddleware wafVar fingerprintedApp
        securedApp       = addSecurityHeaders defaultSecurityConfig wafApp

        earlyDataApp     = if ddosEarlyDataReject ddosCfg
                             then earlyDataGuard securedApp
                             else securedApp

        mHoneypotCfg     = buildHoneypotConfig (configHoneypot config)
        honeypotApp      = case mHoneypotCfg of
          Just hp -> honeypotMiddleware hp mIPJail earlyDataApp
          Nothing -> earlyDataApp

        geoApp = case mGeo of
          Just g  -> geoMiddleware g mIPJail honeypotApp
          Nothing -> honeypotApp

        jailedApp = case mIPJail of
          Just j  -> ipJailMiddleware j geoApp
          Nothing -> geoApp

        shedApp = case mMemShed of
          Just ms -> memoryShedMiddleware ms jailedApp
          Nothing -> jailedApp

        limitedApp = case mRateLimiter of
          Just rl -> rateLimitMiddleware rl shedApp
          Nothing -> shedApp

        warpSettings = applyDDoSSettings ddosCfg mConnLim
                                        (defaultSettings & setPort port)

    case listenTLS listenConfig of
      Nothing -> do
        let app = if shouldRedirect
                    then httpsRedirect limitedApp
                    else limitedApp
        putStrLn $ "* HTTP server listening on :" ++ show port
        if shouldRedirect
          then putStrLn "  Redirecting all traffic to HTTPS"
          else pure ()
        runSettings warpSettings app

      Just tlsConfig -> do
        let isSNI = case tlsSNI tlsConfig of
              Just domains -> not (null domains)
              Nothing      -> False
        if isSNI
          then launchHTTPSWithSNI port tlsConfig limitedApp
          else launchHTTPS port tlsConfig limitedApp

applyDDoSSettings :: DDoSConfig -> Maybe ConnLimiter -> Settings -> Settings
applyDDoSSettings ddos mConnLim s0 =
  let s1Inner = case ddosSlowlorisSeconds ddos of
        Just n  -> setTimeout n s0
        Nothing -> s0
      s1 = case ddosMaxHeaderBytes ddos of
        Just n  -> setMaxTotalHeaderLength n s1Inner
        Nothing -> s1Inner
      s2 = case mConnLim of
        Just cl -> setOnClose (connLimitOnClose cl)
                     (setOnOpen (connLimitOnOpen cl) s1)
        Nothing -> s1
  in s2

launchHTTPS :: Int -> TLSConfig -> Application -> IO ()
launchHTTPS port tlsConfig app =
  case (tlsCert tlsConfig, tlsKey tlsConfig) of
    (Just certFile, Just keyFile) -> do
      tlsResult <- createTLSSettings certFile keyFile
      case tlsResult of
        Left err -> do
          hPutStrLn stderr "ERROR: Failed to load TLS certificate"
          hPutStrLn stderr $ "  " ++ show err
          exitFailure
        Right tlsSettings -> do
          let warpSettings = defaultSettings & setPort port
          putStrLn $ "* HTTPS server listening on :" ++ show port
          putStrLn $ "  Certificate: " ++ certFile
          putStrLn   "  TLS 1.2 + TLS 1.3 enabled"
          putStrLn   "  HTTP/2 enabled (ALPN)"
          putStrLn   "  Strong cipher suites enforced"
          runTLS tlsSettings warpSettings app
    _ -> do
      hPutStrLn stderr "ERROR: TLS configuration requires both cert and key"
      exitFailure

launchHTTPSWithSNI :: Int -> TLSConfig -> Application -> IO ()
launchHTTPSWithSNI port tlsConfig app =
  case (tlsSNI tlsConfig, tlsDefaultCert tlsConfig, tlsDefaultKey tlsConfig) of
    (Just sniDomains, Just defaultCert, Just defaultKey) -> do
      let domainList = [(sniDomain d, sniCert d, sniKey d) | d <- sniDomains]
      tlsResult <- createSNISettings domainList defaultCert defaultKey
      case tlsResult of
        Left err -> do
          hPutStrLn stderr "ERROR: Failed to load SNI certificates"
          hPutStrLn stderr $ "  " ++ show err
          exitFailure
        Right tlsSettings -> do
          let warpSettings = defaultSettings & setPort port
          putStrLn $ "* HTTPS server with SNI listening on :" ++ show port
          putStrLn $ "  SNI domains: " ++ show (length sniDomains) ++ " configured"
          mapM_
            (\d -> putStrLn $
              "    " ++ T.unpack (sniDomain d) ++ " -> " ++ sniCert d)
            sniDomains
          putStrLn $ "  Default certificate: " ++ defaultCert
          putStrLn   "  TLS 1.2 + TLS 1.3 enabled"
          putStrLn   "  HTTP/2 enabled (ALPN)"
          putStrLn   "  Strong cipher suites enforced"
          runTLS tlsSettings warpSettings app
    _ -> do
      hPutStrLn stderr "ERROR: SNI requires sni, default_cert, and default_key"
      exitFailure

proxyApp :: Config -> Map Text LoadBalancer -> Manager -> Application
proxyApp config loadBalancers manager req respond = do
  let hostHeader  = lookup "Host" (requestHeaders req)
      requestPath = rawPathInfo req
      headers     = requestHeaders req
      connType    = detectConnectionType headers

  case selectRoute config hostHeader requestPath of
    Nothing -> do
      hPutStrLn stderr "ERROR: No route found for request"
      respond $ responseLBS
        status404
        [(hContentType, contentTypePlain)]
        bodyNotFound

    Just (upstreamName, _pathRoute) ->
      case Map.lookup upstreamName loadBalancers of
        Nothing -> do
          hPutStrLn stderr $
            "ERROR: Load balancer not found: " ++ T.unpack upstreamName
          respond $ responseLBS
            status500
            [(hContentType, contentTypePlain)]
            bodyUpstreamMisconfigured

        Just loadBalancer -> do
          mBackend <- selectBackend loadBalancer
          case mBackend of
            Nothing -> do
              hPutStrLn stderr "ERROR: No healthy backends available"
              respond $ responseLBS
                status503
                [(hContentType, contentTypePlain)]
                bodyNoHealthyBackends

            Just backend -> case connType of
              WebSocket -> do
                hPutStrLn stderr "[WS] WebSocket upgrade detected"
                handleWebSocketUpgrade req respond backend
              _ ->
                forwardRegular manager backend req respond

forwardRegular
  :: Manager
  -> RuntimeBackend
  -> Request
  -> (Response -> IO ResponseReceived)
  -> IO ResponseReceived
forwardRegular manager backend req respond = do
  result <- try $ trackConnection backend $
    forwardRequest manager req (rbHost backend) respond
  case result of
    Left (err :: SomeException) -> do
      hPutStrLn stderr $ "ERROR: " ++ show err
      respond $ responseLBS
        status502
        [(hContentType, contentTypePlain)]
        bodyBadGateway
    Right responseReceived ->
      pure responseReceived

handleWebSocketUpgrade
  :: Request
  -> (Response -> IO ResponseReceived)
  -> RuntimeBackend
  -> IO ResponseReceived
handleWebSocketUpgrade req respond backend = do
  let backendHost = rbHost backend
      backupResponse = responseLBS
        status502
        [(hContentType, contentTypePlain)]
        bodyWebSocketUpgradeFailed
  respond $ responseRaw (wsHandler req backendHost) backupResponse

wsHandler
  :: Request
  -> Text
  -> IO ByteString
  -> (ByteString -> IO ())
  -> IO ()
wsHandler req backendHost recv send = do
  hPutStrLn stderr $ "[WS] Starting WebSocket tunnel to " ++ T.unpack backendHost
  tunnelWebSocket req backendHost send recv

selectRoute
  :: Config
  -> Maybe BS.ByteString
  -> BS.ByteString
  -> Maybe (Text, PathRoute)
selectRoute config hostHeader requestPath = case hostHeader of
  Nothing   -> Nothing
  Just host -> do
    let hostText        = TE.decodeUtf8 host
        matchingRoutes  = filter (\r -> routeHost r == hostText)
                                 (configRoutes config)
    route <- listToMaybe matchingRoutes
    let requestPathText = TE.decodeUtf8 requestPath
        sortedPaths     = sortBy
                            (comparing (negate . T.length . pathRoutePath))
                            (routePaths route)
        matchingPaths   = filter
                            (\p -> pathMatches (pathRoutePath p) requestPathText)
                            sortedPaths
    pathRoute <- listToMaybe matchingPaths
    return (pathRouteUpstream pathRoute, pathRoute)

pathMatches :: Text -> Text -> Bool
pathMatches pattern requestPath =
  pattern == "/" || T.isPrefixOf pattern requestPath

selectUpstream
  :: Config -> Maybe BS.ByteString -> BS.ByteString -> Maybe Text
selectUpstream config hostHeader requestPath =
  fst <$> selectRoute config hostHeader requestPath

forwardRequest
  :: Manager
  -> Request
  -> Text
  -> (Response -> IO ResponseReceived)
  -> IO ResponseReceived
forwardRequest manager clientReq backendHost respond = do
  let backendUrl = httpScheme ++ T.unpack backendHost
                ++ BS8.unpack (rawPathInfo clientReq)
                ++ BS8.unpack (rawQueryString clientReq)

  initReq <- parseRequest backendUrl

  let streamingBody = case requestBodyLength clientReq of
        ChunkedBody ->
          RequestBodyStreamChunked $ \needsPopper ->
            needsPopper (getRequestBodyChunk clientReq)
        KnownLength len ->
          RequestBodyStream (fromIntegral len) $ \needsPopper ->
            needsPopper (getRequestBodyChunk clientReq)

      backendReq = initReq
        { HTTP.method = requestMethod clientReq
        , HTTP.requestHeaders = filterRequestHeaders (requestHeaders clientReq)
        , HTTP.requestBody = streamingBody
        }

      upstreamMicros = tcUpstreamReadSeconds defaultTimeoutConfig
                     * microsPerSecond

  mResult <- timeout upstreamMicros $
    withResponse backendReq manager $ \backendResponse -> do
      let status     = HTTP.responseStatus backendResponse
          headers    = HTTP.responseHeaders backendResponse
          bodyReader = HTTP.responseBody backendResponse
      if shouldStreamResponse headers
        then do
          hPutStrLn stderr "[STREAM] Streaming response detected"
          respond $ responseStream status (filterResponseHeaders headers) $
            \write flush -> do
              let loop = do
                    chunk <- brRead bodyReader
                    unless (BS.null chunk) $ do
                      write (byteString chunk)
                      flush
                      loop
              loop
        else do
          body <- readFullBody bodyReader
          respond $ responseLBS status (filterResponseHeaders headers) body

  case mResult of
    Just rr -> pure rr
    Nothing -> respond $ responseLBS
      status504
      [(hContentType, contentTypePlain)]
      bodyGatewayTimeout

shouldStreamResponse :: [(HeaderName, BS.ByteString)] -> Bool
shouldStreamResponse headers = isSSE || isChunkedWithoutLength
  where
    isSSE = case lookup "Content-Type" headers of
      Just ct -> eventStreamContentType `BS.isInfixOf` ct
      Nothing -> False
    isChunkedWithoutLength = hasChunkedEncoding && not hasContentLength
    hasChunkedEncoding = case lookup "Transfer-Encoding" headers of
      Just te -> chunkedEncoding `BS.isInfixOf` te
      Nothing -> False
    hasContentLength = case lookup "Content-Length" headers of
      Just _  -> True
      Nothing -> False

readFullBody :: HTTP.BodyReader -> IO LBS.ByteString
readFullBody bodyReader = LBS.fromChunks <$> go
  where
    go = do
      chunk <- brRead bodyReader
      if BS.null chunk
        then pure []
        else do
          rest <- go
          pure (chunk : rest)

filterResponseHeaders
  :: [(HeaderName, BS.ByteString)] -> [(HeaderName, BS.ByteString)]
filterResponseHeaders =
  filter (\(name, _) -> name `notElem` hopByHopResponseHeaders)

filterRequestHeaders
  :: [(HeaderName, BS.ByteString)] -> [(HeaderName, BS.ByteString)]
filterRequestHeaders =
  filter (\(name, _) -> name `notElem` hopByHopRequestHeaders)
