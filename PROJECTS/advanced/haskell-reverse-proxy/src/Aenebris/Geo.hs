{-
©AngelaMos | 2026
Geo.hs
-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Aenebris.Geo
  ( GeoAction(..)
  , GeoConfig(..)
  , GeoConfigYaml(..)
  , GeoInfo(..)
  , GeoDecision(..)
  , AsnWindow(..)
  , Geo(..)
  , defaultGeoLanguage
  , defaultGeoConcentrationWindowSeconds
  , defaultGeoConcentrationThreshold
  , defaultGeoJailCooldownSeconds
  , defaultGeoSweepIntervalMicros
  , defaultGeoFlaggedAsns
  , geoResponseHeaderName
  , parseGeoAction
  , sockAddrToIP
  , countryBlocked
  , emptyGeoInfo
  , lookupGeo
  , bumpAsnCounter
  , asnConcentrationScore
  , purgeAsnCounters
  , startAsnSweeper
  , decideGeo
  , buildGeoConfig
  , openGeo
  , geoMiddleware
  , renderGeoHeader
  ) where

import Aenebris.DDoS.IPJail (IPJail, jail)
import Aenebris.RateLimit (clientIPKey)

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async)
import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , modifyTVar'
  , newTVarIO
  , readTVar
  , writeTVar
  )
import Control.Monad (forever, when)
import Data.Aeson (FromJSON(..), withObject, (.:?), (.!=))
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as LBS
import Data.GeoIP2 (GeoDB, GeoResult(..), AS(..), findGeoData, openGeoDB)
import Data.IP (IP(..), fromHostAddress, fromHostAddress6)
import Data.List (minimumBy)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Ord (comparing)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import GHC.Generics (Generic)
import Network.HTTP.Types (HeaderName, status403)
import Network.Socket (SockAddr(..))
import Network.Wai
  ( Middleware
  , mapResponseHeaders
  , remoteHost
  , responseLBS
  )

defaultGeoLanguage :: Text
defaultGeoLanguage = "en"

defaultGeoConcentrationWindowSeconds :: Int
defaultGeoConcentrationWindowSeconds = 60

defaultGeoConcentrationThreshold :: Int
defaultGeoConcentrationThreshold = 500

defaultGeoJailCooldownSeconds :: Int
defaultGeoJailCooldownSeconds = 600

defaultGeoSweepIntervalMicros :: Int
defaultGeoSweepIntervalMicros = 60_000_000

defaultGeoFlaggedAsns :: [Int]
defaultGeoFlaggedAsns = []

defaultGeoAsnCountCap :: Int
defaultGeoAsnCountCap = 200_000

geoResponseHeaderName :: HeaderName
geoResponseHeaderName = "x-aenebris-geo"

data GeoAction
  = GeoActionLog
  | GeoActionJail
  deriving (Show, Eq, Generic)

parseGeoAction :: Text -> GeoAction
parseGeoAction t = case T.toLower t of
  "jail" -> GeoActionJail
  "log" -> GeoActionLog
  _ -> GeoActionLog

data GeoConfig = GeoConfig
  { gcCountryDb :: !(Maybe FilePath)
  , gcAsnDb :: !(Maybe FilePath)
  , gcBlockedCountries :: ![Text]
  , gcAllowedCountries :: ![Text]
  , gcFlaggedAsns :: ![Int]
  , gcConcentrationWindowSeconds :: !Int
  , gcConcentrationThreshold :: !Int
  , gcJailCooldownSeconds :: !Int
  , gcAction :: !GeoAction
  , gcAnnotateHeader :: !Bool
  , gcLanguage :: !Text
  } deriving (Show, Eq)

data GeoConfigYaml = GeoConfigYaml
  { gcyEnabled :: !Bool
  , gcyCountryDb :: !(Maybe FilePath)
  , gcyAsnDb :: !(Maybe FilePath)
  , gcyBlockedCountries :: ![Text]
  , gcyAllowedCountries :: ![Text]
  , gcyFlaggedAsns :: ![Int]
  , gcyWindowSeconds :: !(Maybe Int)
  , gcyThreshold :: !(Maybe Int)
  , gcyJailCooldownSeconds :: !(Maybe Int)
  , gcyAction :: !(Maybe Text)
  , gcyAnnotateHeader :: !Bool
  , gcyLanguage :: !(Maybe Text)
  } deriving (Show, Eq, Generic)

instance FromJSON GeoConfigYaml where
  parseJSON = withObject "GeoConfigYaml" $ \v -> GeoConfigYaml
    <$> v .:? "enabled" .!= False
    <*> v .:? "country_db"
    <*> v .:? "asn_db"
    <*> v .:? "blocked_countries" .!= []
    <*> v .:? "allowed_countries" .!= []
    <*> v .:? "flagged_asns" .!= []
    <*> v .:? "window_seconds"
    <*> v .:? "threshold"
    <*> v .:? "jail_cooldown_seconds"
    <*> v .:? "action"
    <*> v .:? "annotate_header" .!= True
    <*> v .:? "language"

buildGeoConfig :: Maybe GeoConfigYaml -> Maybe GeoConfig
buildGeoConfig Nothing = Nothing
buildGeoConfig (Just y)
  | not (gcyEnabled y) = Nothing
  | otherwise = Just GeoConfig
      { gcCountryDb = gcyCountryDb y
      , gcAsnDb = gcyAsnDb y
      , gcBlockedCountries = map T.toUpper (gcyBlockedCountries y)
      , gcAllowedCountries = map T.toUpper (gcyAllowedCountries y)
      , gcFlaggedAsns = gcyFlaggedAsns y
      , gcConcentrationWindowSeconds =
          fromMaybe defaultGeoConcentrationWindowSeconds (gcyWindowSeconds y)
      , gcConcentrationThreshold =
          fromMaybe defaultGeoConcentrationThreshold (gcyThreshold y)
      , gcJailCooldownSeconds =
          fromMaybe defaultGeoJailCooldownSeconds (gcyJailCooldownSeconds y)
      , gcAction = maybe GeoActionLog parseGeoAction (gcyAction y)
      , gcAnnotateHeader = gcyAnnotateHeader y
      , gcLanguage = fromMaybe defaultGeoLanguage (gcyLanguage y)
      }

data GeoInfo = GeoInfo
  { giCountryISO :: !(Maybe Text)
  , giAsnNumber :: !(Maybe Int)
  , giAsnOrg :: !(Maybe Text)
  , giFlaggedAsn :: !Bool
  } deriving (Show, Eq)

emptyGeoInfo :: GeoInfo
emptyGeoInfo = GeoInfo Nothing Nothing Nothing False

data GeoDecision
  = GeoAllow
  | GeoBlockCountry !Text
  | GeoJailAsn !Int !Double
  deriving (Show, Eq)

data AsnWindow = AsnWindow
  { awCount :: !Int
  , awWindowStart :: !POSIXTime
  } deriving (Show, Eq)

data Geo = Geo
  { geoCountryDb :: !(Maybe GeoDB)
  , geoAsnDb :: !(Maybe GeoDB)
  , geoConfig :: !GeoConfig
  , geoAsnCounts :: !(TVar (Map Int AsnWindow))
  }

openGeo :: GeoConfig -> IO Geo
openGeo cfg = do
  countryDb <- traverse openGeoDB (gcCountryDb cfg)
  asnDb <- traverse openGeoDB (gcAsnDb cfg)
  counts <- newTVarIO Map.empty
  pure Geo
    { geoCountryDb = countryDb
    , geoAsnDb = asnDb
    , geoConfig = cfg
    , geoAsnCounts = counts
    }

sockAddrToIP :: SockAddr -> Maybe IP
sockAddrToIP (SockAddrInet _ ha) = Just (IPv4 (fromHostAddress ha))
sockAddrToIP (SockAddrInet6 _ _ ha6 _) = Just (IPv6 (fromHostAddress6 ha6))
sockAddrToIP (SockAddrUnix _) = Nothing

countryBlocked :: GeoConfig -> Maybe Text -> Maybe Text
countryBlocked GeoConfig{..} mIso = case mIso of
  Nothing
    | not (null gcAllowedCountries) -> Just "??"
    | otherwise -> Nothing
  Just iso ->
    let up = T.toUpper iso
        inBlocked = up `elem` gcBlockedCountries
        inAllowed = null gcAllowedCountries || up `elem` gcAllowedCountries
    in if inBlocked || not inAllowed then Just up else Nothing

lookupGeo :: Geo -> IP -> IO GeoInfo
lookupGeo Geo{..} ip = do
  let lang = gcLanguage geoConfig
      countryRes = (\db -> findGeoData db lang ip) <$> geoCountryDb
      asnRes = (\db -> findGeoData db lang ip) <$> geoAsnDb
      country = case countryRes of
        Just (Right r) -> geoCountryISO r
        _ -> Nothing
      (asn, org) = case asnRes of
        Just (Right r) -> case geoAS r of
          Just a -> (Just (asNumber a), Just (asOrganization a))
          Nothing -> (Nothing, Nothing)
        _ -> (Nothing, Nothing)
      flagged = case asn of
        Just n -> n `elem` gcFlaggedAsns geoConfig
        Nothing -> False
  pure GeoInfo
    { giCountryISO = country
    , giAsnNumber = asn
    , giAsnOrg = org
    , giFlaggedAsn = flagged
    }

bumpAsnCounter :: Geo -> Int -> POSIXTime -> STM Int
bumpAsnCounter Geo{..} n now = do
  let window = fromIntegral (gcConcentrationWindowSeconds geoConfig) :: POSIXTime
  m <- readTVar geoAsnCounts
  let entry = case Map.lookup n m of
        Just w
          | now - awWindowStart w < window ->
              w { awCount = awCount w + 1 }
        _ -> AsnWindow { awCount = 1, awWindowStart = now }
      inserted = Map.insert n entry m
      bounded = capAsnCounts inserted
  writeTVar geoAsnCounts $! bounded
  pure (awCount entry)

capAsnCounts :: Map Int AsnWindow -> Map Int AsnWindow
capAsnCounts m
  | Map.size m <= defaultGeoAsnCountCap = m
  | otherwise =
      let oldestKey = fst $ minimumBy
            (comparing (awWindowStart . snd))
            (Map.toList m)
      in Map.delete oldestKey m

asnConcentrationScore :: Geo -> Int -> Double
asnConcentrationScore Geo{..} count =
  let threshold = max 1 (gcConcentrationThreshold geoConfig)
      ratio = fromIntegral count / fromIntegral threshold :: Double
  in min 1.0 (max 0.0 ratio)

purgeAsnCounters :: Geo -> POSIXTime -> STM Int
purgeAsnCounters Geo{..} now = do
  let window = fromIntegral (gcConcentrationWindowSeconds geoConfig) :: POSIXTime
  m <- readTVar geoAsnCounts
  let (stale, fresh) = Map.partition (\w -> now - awWindowStart w >= window) m
  modifyTVar' geoAsnCounts (const fresh)
  pure (Map.size stale)

startAsnSweeper :: Geo -> IO (Async ())
startAsnSweeper g = async $ forever $ do
  threadDelay defaultGeoSweepIntervalMicros
  now <- getPOSIXTime
  _ <- atomically (purgeAsnCounters g now)
  pure ()

decideGeo :: GeoConfig -> GeoInfo -> Int -> GeoDecision
decideGeo cfg info count =
  case countryBlocked cfg (giCountryISO info) of
    Just iso -> GeoBlockCountry iso
    Nothing ->
      let threshold = gcConcentrationThreshold cfg
          safeThreshold = max 1 threshold
          score = min 1.0
                $ fromIntegral count / fromIntegral safeThreshold :: Double
          shouldJail = gcAction cfg == GeoActionJail
                    && giFlaggedAsn info
                    && count >= threshold
      in case giAsnNumber info of
           Just n | shouldJail -> GeoJailAsn n score
           _ -> GeoAllow

renderGeoHeader :: GeoInfo -> Int -> ByteString
renderGeoHeader info count =
  let countryPart = case giCountryISO info of
        Just iso -> "country=" <> TE.encodeUtf8 iso
        Nothing -> "country=??"
      asnPart = case giAsnNumber info of
        Just n -> "asn=" <> BC.pack (show n)
        Nothing -> "asn=0"
      flagPart = if giFlaggedAsn info then "flag=1" else "flag=0"
      countPart = "count=" <> BC.pack (show count)
  in BC.intercalate " " [countryPart, asnPart, flagPart, countPart]

forbiddenByCountry :: Text -> LBS.ByteString
forbiddenByCountry iso =
  LBS.fromStrict ("403 Forbidden: country " <> TE.encodeUtf8 iso <> " is restricted")

geoMiddleware :: Geo -> Maybe IPJail -> Middleware
geoMiddleware g@Geo{..} mJail app req respond = do
  let mIp = sockAddrToIP (remoteHost req)
  (info, count) <- case mIp of
    Nothing -> pure (emptyGeoInfo, 0)
    Just ip -> do
      infoRaw <- lookupGeo g ip
      now <- getPOSIXTime
      c <- case giAsnNumber infoRaw of
        Just n -> atomically (bumpAsnCounter g n now)
        Nothing -> pure 0
      pure (infoRaw, c)
  let decision = decideGeo geoConfig info count
      annotate = gcAnnotateHeader geoConfig
      headerBS = renderGeoHeader info count
      withGeoHeader =
        if annotate
          then mapResponseHeaders ((geoResponseHeaderName, headerBS) :)
          else id
  case decision of
    GeoAllow -> app req (respond . withGeoHeader)
    GeoBlockCountry iso -> respond $ withGeoHeader $ responseLBS status403
      [ ("Content-Type", "text/plain; charset=utf-8")
      , ("Cache-Control", "no-store")
      ]
      (forbiddenByCountry iso)
    GeoJailAsn asn _score -> do
      now <- getPOSIXTime
      when (isJust mJail) $
        atomically $ case mJail of
          Just j -> jail j (clientIPKey req)
                           (fromIntegral (gcJailCooldownSeconds geoConfig))
                           ("geo:asn:" <> BC.pack (show asn))
                           now
          Nothing -> pure ()
      respond $ withGeoHeader $ responseLBS status403
        [ ("Content-Type", "text/plain; charset=utf-8")
        , ("Cache-Control", "no-store")
        ]
        "403 Forbidden: source network is temporarily restricted"
