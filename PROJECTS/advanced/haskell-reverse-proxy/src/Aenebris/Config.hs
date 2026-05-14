{-
©AngelaMos | 2026
Config.hs
-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Aenebris.Config
  ( Config(..)
  , ListenConfig(..)
  , TLSConfig(..)
  , SNIDomain(..)
  , Upstream(..)
  , Server(..)
  , HealthCheck(..)
  , Route(..)
  , PathRoute(..)
  , DDoSConfig(..)
  , defaultDDoSConfig
  , loadConfig
  , validateConfig
  ) where

import Aenebris.Honeypot (HoneypotConfigYaml)
import Aenebris.Geo (GeoConfigYaml)

import Control.Monad (forM_, when)
import Data.Aeson
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Yaml (decodeFileEither)
import GHC.Generics

supportedConfigVersion :: Int
supportedConfigVersion = 1

minPort :: Int
minPort = 1

maxPort :: Int
maxPort = 65535

minServerWeight :: Int
minServerWeight = 1

data Config = Config
  { configVersion   :: !Int
  , configListen    :: ![ListenConfig]
  , configUpstreams :: ![Upstream]
  , configRoutes    :: ![Route]
  , configRateLimit :: !(Maybe Text)
  , configDDoS      :: !(Maybe DDoSConfig)
  , configHoneypot  :: !(Maybe HoneypotConfigYaml)
  , configGeo       :: !(Maybe GeoConfigYaml)
  } deriving (Show, Eq, Generic)

instance FromJSON Config where
  parseJSON = withObject "Config" $ \v -> Config
    <$> v .:  "version"
    <*> v .:  "listen"
    <*> v .:  "upstreams"
    <*> v .:  "routes"
    <*> v .:? "rate_limit"
    <*> v .:? "ddos"
    <*> v .:? "honeypot"
    <*> v .:? "geo"

data DDoSConfig = DDoSConfig
  { ddosEarlyDataReject      :: !Bool
  , ddosPerIPConnections     :: !(Maybe Int)
  , ddosMemoryShedBytes      :: !(Maybe Integer)
  , ddosMemoryShedHighWater  :: !(Maybe Double)
  , ddosMaxConcurrentStreams :: !(Maybe Int)
  , ddosMaxHeaderBytes       :: !(Maybe Int)
  , ddosSlowlorisSeconds     :: !(Maybe Int)
  , ddosJailCooldownSeconds  :: !(Maybe Int)
  , ddosReusePort            :: !Bool
  } deriving (Show, Eq, Generic)

instance FromJSON DDoSConfig where
  parseJSON = withObject "DDoSConfig" $ \v -> DDoSConfig
    <$> v .:? "early_data_reject"      .!= True
    <*> v .:? "per_ip_connections"
    <*> v .:? "memory_shed_bytes"
    <*> v .:? "memory_shed_high_water"
    <*> v .:? "max_concurrent_streams"
    <*> v .:? "max_header_bytes"
    <*> v .:? "slowloris_seconds"
    <*> v .:? "jail_cooldown_seconds"
    <*> v .:? "reuse_port"             .!= False

defaultDDoSConfig :: DDoSConfig
defaultDDoSConfig = DDoSConfig
  { ddosEarlyDataReject      = True
  , ddosPerIPConnections     = Nothing
  , ddosMemoryShedBytes      = Nothing
  , ddosMemoryShedHighWater  = Nothing
  , ddosMaxConcurrentStreams = Nothing
  , ddosMaxHeaderBytes       = Nothing
  , ddosSlowlorisSeconds     = Nothing
  , ddosJailCooldownSeconds  = Nothing
  , ddosReusePort            = False
  }

data ListenConfig = ListenConfig
  { listenPort          :: !Int
  , listenTLS           :: !(Maybe TLSConfig)
  , listenRedirectHTTPS :: !(Maybe Bool)
  } deriving (Show, Eq, Generic)

instance FromJSON ListenConfig where
  parseJSON = withObject "ListenConfig" $ \v -> ListenConfig
    <$> v .:  "port"
    <*> v .:? "tls"
    <*> v .:? "redirect_https"

data TLSConfig = TLSConfig
  { tlsCert        :: !(Maybe FilePath)
  , tlsKey         :: !(Maybe FilePath)
  , tlsSNI         :: !(Maybe [SNIDomain])
  , tlsDefaultCert :: !(Maybe FilePath)
  , tlsDefaultKey  :: !(Maybe FilePath)
  } deriving (Show, Eq, Generic)

instance FromJSON TLSConfig where
  parseJSON = withObject "TLSConfig" $ \v -> TLSConfig
    <$> v .:? "cert"
    <*> v .:? "key"
    <*> v .:? "sni"
    <*> v .:? "default_cert"
    <*> v .:? "default_key"

data SNIDomain = SNIDomain
  { sniDomain :: !Text
  , sniCert   :: !FilePath
  , sniKey    :: !FilePath
  } deriving (Show, Eq, Generic)

instance FromJSON SNIDomain where
  parseJSON = withObject "SNIDomain" $ \v -> SNIDomain
    <$> v .: "domain"
    <*> v .: "cert"
    <*> v .: "key"

data Upstream = Upstream
  { upstreamName        :: !Text
  , upstreamServers     :: ![Server]
  , upstreamHealthCheck :: !(Maybe HealthCheck)
  } deriving (Show, Eq, Generic)

instance FromJSON Upstream where
  parseJSON = withObject "Upstream" $ \v -> Upstream
    <$> v .:  "name"
    <*> v .:  "servers"
    <*> v .:? "health_check"

data Server = Server
  { serverHost   :: !Text
  , serverWeight :: !Int
  } deriving (Show, Eq, Generic)

instance FromJSON Server where
  parseJSON = withObject "Server" $ \v -> Server
    <$> v .: "host"
    <*> v .: "weight"

data HealthCheck = HealthCheck
  { healthCheckPath     :: !Text
  , healthCheckInterval :: !Text
  } deriving (Show, Eq, Generic)

instance FromJSON HealthCheck where
  parseJSON = withObject "HealthCheck" $ \v -> HealthCheck
    <$> v .: "path"
    <*> v .: "interval"

data Route = Route
  { routeHost  :: !Text
  , routePaths :: ![PathRoute]
  } deriving (Show, Eq, Generic)

instance FromJSON Route where
  parseJSON = withObject "Route" $ \v -> Route
    <$> v .: "host"
    <*> v .: "paths"

data PathRoute = PathRoute
  { pathRoutePath      :: !Text
  , pathRouteUpstream  :: !Text
  , pathRouteRateLimit :: !(Maybe Text)
  } deriving (Show, Eq, Generic)

instance FromJSON PathRoute where
  parseJSON = withObject "PathRoute" $ \v -> PathRoute
    <$> v .:  "path"
    <*> v .:  "upstream"
    <*> v .:? "rate_limit"

loadConfig :: FilePath -> IO (Either String Config)
loadConfig path = do
  result <- decodeFileEither path
  pure $ case result of
    Left err     -> Left (show err)
    Right config -> Right config

validateConfig :: Config -> Either String ()
validateConfig config = do
  when (configVersion config /= supportedConfigVersion) $
    Left ("Unsupported config version (expected: "
            ++ show supportedConfigVersion ++ ")")

  when (null (configListen config)) $
    Left "At least one listen port must be specified"

  forM_ (configListen config) $ \listen -> do
    let port = listenPort listen
    when (port < minPort || port > maxPort) $
      Left ("Invalid port number: " ++ show port)
    case listenTLS listen of
      Nothing       -> pure ()
      Just tlsConf  -> validateTLS tlsConf

  when (null (configUpstreams config)) $
    Left "At least one upstream must be specified"

  let upstreamNames = map upstreamName (configUpstreams config)
  when (length upstreamNames /= length (nub upstreamNames)) $
    Left "Upstream names must be unique"

  forM_ (configUpstreams config) $ \upstream -> do
    when (null (upstreamServers upstream)) $
      Left ("Upstream '" ++ T.unpack (upstreamName upstream)
              ++ "' has no servers")
    forM_ (upstreamServers upstream) $ \server ->
      when (serverWeight server < minServerWeight) $
        Left ("Server weight must be positive: "
                ++ T.unpack (serverHost server))

  when (null (configRoutes config)) $
    Left "At least one route must be specified"

  forM_ (configRoutes config) $ \route -> do
    when (null (routePaths route)) $
      Left ("Route for host '" ++ T.unpack (routeHost route)
              ++ "' has no paths")
    forM_ (routePaths route) $ \pathRoute -> do
      let upstreamRef = pathRouteUpstream pathRoute
      when (upstreamRef `notElem` upstreamNames) $
        Left ("Unknown upstream referenced: '"
                ++ T.unpack upstreamRef ++ "'")

  pure ()

validateTLS :: TLSConfig -> Either String ()
validateTLS tlsConf = do
  let hasSingleCert = case (tlsCert tlsConf, tlsKey tlsConf) of
        (Just _, Just _) -> True
        _                -> False
      hasSNI = case (tlsSNI tlsConf, tlsDefaultCert tlsConf, tlsDefaultKey tlsConf) of
        (Just sniDomains, Just _, Just _) -> not (null sniDomains)
        _                                  -> False

  when (not hasSingleCert && not hasSNI) $
    Left "TLS configuration must specify either (cert + key) or (sni + default_cert + default_key)"

  when (hasSingleCert && hasSNI) $
    Left "TLS configuration cannot have both single cert and SNI configuration"

  when hasSingleCert $
    case (tlsCert tlsConf, tlsKey tlsConf) of
      (Just _, Nothing) -> Left "TLS cert specified but key missing"
      (Nothing, Just _) -> Left "TLS key specified but cert missing"
      _                 -> pure ()

  when hasSNI $
    case (tlsDefaultCert tlsConf, tlsDefaultKey tlsConf) of
      (Just _, Nothing)     -> Left "SNI default_cert specified but default_key missing"
      (Nothing, Just _)     -> Left "SNI default_key specified but default_cert missing"
      (Nothing, Nothing)    -> Left "SNI configuration requires default_cert and default_key"
      _                     -> pure ()

  pure ()
