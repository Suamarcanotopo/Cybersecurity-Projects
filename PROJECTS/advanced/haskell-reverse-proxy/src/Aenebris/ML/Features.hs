{-
©AngelaMos | 2026
Features.hs
-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Aenebris.ML.Features
  ( FeatureVector(..)
  , FeatureContext(..)
  , emptyFeatureContext
  , extractFeatures
  , featureVectorLength
  , featureVectorToList
  , featureVectorToVector
  , featureNames
  , headerCountCap
  , pathDepthCap
  , queryParamCountCap
  , userAgentLengthCap
  , pathEntropyMax
  , acceptValueLengthCap
  , botKeywordPatterns
  , headlessPatterns
  , suspiciousPathExtensions
  , commonBrowserMarkers
  , idempotentMethods
  , commonBrowserMarkerThreshold
  , secFetchModeValidValues
  , secFetchDestNavigationValues
  , headerOrderTrackedNames
  , chromeHeaderCanonicalOrder
  , firefoxHeaderCanonicalOrder
  , shannonEntropyBytes
  , uaSecChConsistency
  , uaContainsBotKeyword
  , uaContainsHeadlessMarker
  , uaIsCommonBrowser
  , uaPlatformConsistency
  , pathDepth
  , pathHasSuspiciousExtension
  , methodIsIdempotent
  , secFetchModeIsValid
  , secFetchTripleIsCoherent
  , acceptIsWildcard
  , headerOrderIsCanonicalBrowser
  , clamp01
  , normalizedRatio
  ) where

import Aenebris.Geo (GeoInfo(..), emptyGeoInfo)

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.CaseInsensitive (CI)
import Data.Char (toLower)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Vector.Unboxed (Vector)
import qualified Data.Vector.Unboxed as VU
import Data.Word (Word8)
import Network.Wai
  ( Request
  , queryString
  , rawPathInfo
  , requestHeaders
  , requestMethod
  )

headerCountCap :: Double
headerCountCap = 32.0

pathDepthCap :: Double
pathDepthCap = 16.0

queryParamCountCap :: Double
queryParamCountCap = 32.0

userAgentLengthCap :: Double
userAgentLengthCap = 256.0

pathEntropyMax :: Double
pathEntropyMax = 8.0

acceptValueLengthCap :: Double
acceptValueLengthCap = 200.0

commonBrowserMarkerThreshold :: Int
commonBrowserMarkerThreshold = 2

secFetchModeValidValues :: [ByteString]
secFetchModeValidValues =
  ["cors", "no-cors", "navigate", "same-origin", "websocket"]

secFetchDestNavigationValues :: [ByteString]
secFetchDestNavigationValues =
  ["document", "iframe", "frame", "embed", "object"]

secFetchSiteValidValues :: [ByteString]
secFetchSiteValidValues =
  ["none", "same-origin", "same-site", "cross-site"]

headerOrderTrackedNames :: [CI ByteString]
headerOrderTrackedNames =
  ["host", "user-agent", "accept", "accept-encoding", "accept-language"]

chromeHeaderCanonicalOrder :: [CI ByteString]
chromeHeaderCanonicalOrder =
  ["host", "user-agent", "accept", "accept-encoding", "accept-language"]

firefoxHeaderCanonicalOrder :: [CI ByteString]
firefoxHeaderCanonicalOrder =
  ["host", "user-agent", "accept", "accept-language", "accept-encoding"]

botKeywordPatterns :: [ByteString]
botKeywordPatterns =
  [ "bot"
  , "crawl"
  , "spider"
  , "scrape"
  , "fetch"
  , "monitor"
  , "checker"
  , "preview"
  , "wget"
  , "curl"
  , "python-requests"
  , "go-http-client"
  , "java/"
  , "okhttp"
  , "libwww"
  , "httpclient"
  ]

headlessPatterns :: [ByteString]
headlessPatterns =
  [ "headlesschrome"
  , "phantomjs"
  , "puppeteer"
  , "playwright"
  , "selenium"
  , "webdriver"
  , "nightmare"
  , "splash"
  ]

suspiciousPathExtensions :: [ByteString]
suspiciousPathExtensions =
  [ ".php"
  , ".asp"
  , ".aspx"
  , ".cgi"
  , ".env"
  , ".bak"
  , ".sql"
  , ".log"
  , ".swp"
  , ".old"
  , ".htaccess"
  , ".htpasswd"
  , ".git"
  , ".ini"
  , ".conf"
  , ".yml"
  , ".yaml"
  , ".pem"
  , ".key"
  ]

commonBrowserMarkers :: [ByteString]
commonBrowserMarkers =
  [ "mozilla/5.0"
  , "applewebkit"
  , "chrome/"
  , "safari/"
  , "firefox/"
  , "edg/"
  , "gecko/"
  , "version/"
  ]

idempotentMethods :: [ByteString]
idempotentMethods = ["GET", "HEAD", "OPTIONS", "TRACE"]

chromiumFamilyMarkers :: [ByteString]
chromiumFamilyMarkers = ["chrome/", "edg/", "opr/", "chromium/", "yabrowser/"]

acceptLanguageHeader :: CI ByteString
acceptLanguageHeader = "accept-language"

userAgentHeader :: CI ByteString
userAgentHeader = "user-agent"

acceptEncodingHeader :: CI ByteString
acceptEncodingHeader = "accept-encoding"

refererHeader :: CI ByteString
refererHeader = "referer"

cookieHeader :: CI ByteString
cookieHeader = "cookie"

secChUaHeader :: CI ByteString
secChUaHeader = "sec-ch-ua"

secChUaPlatformHeader :: CI ByteString
secChUaPlatformHeader = "sec-ch-ua-platform"

secFetchSiteHeader :: CI ByteString
secFetchSiteHeader = "sec-fetch-site"

secFetchModeHeader :: CI ByteString
secFetchModeHeader = "sec-fetch-mode"

secFetchDestHeader :: CI ByteString
secFetchDestHeader = "sec-fetch-dest"

acceptHeader :: CI ByteString
acceptHeader = "accept"

clamp01 :: Double -> Double
clamp01 x
  | x < 0.0 = 0.0
  | x > 1.0 = 1.0
  | otherwise = x

normalizedRatio :: Int -> Double -> Double
normalizedRatio n cap
  | cap <= 0.0 = 0.0
  | otherwise = clamp01 (fromIntegral n / cap)

asciiToLower :: ByteString -> ByteString
asciiToLower = BC.map toLower

shannonEntropyBytes :: ByteString -> Double
shannonEntropyBytes bs
  | BS.null bs = 0.0
  | otherwise =
      let !total = fromIntegral (BS.length bs) :: Double
          freq :: Map Word8 Int
          freq = BS.foldl'
                   (\m b -> Map.insertWith (+) b 1 m)
                   Map.empty
                   bs
          step !acc !c =
            let p = fromIntegral c / total
            in acc - p * logBase 2 p
      in Map.foldl' step 0.0 freq

uaSecChConsistency :: Maybe ByteString -> Maybe ByteString -> Double
uaSecChConsistency mUa mSecCh = case mSecCh of
  Nothing -> 1.0
  Just _ -> case mUa of
    Nothing -> 0.0
    Just ua ->
      let lower = asciiToLower ua
          isChromium = any (`BS.isInfixOf` lower) chromiumFamilyMarkers
      in if isChromium then 1.0 else 0.0

uaContainsBotKeyword :: ByteString -> Bool
uaContainsBotKeyword ua =
  let lower = asciiToLower ua
  in any (`BS.isInfixOf` lower) botKeywordPatterns

uaContainsHeadlessMarker :: ByteString -> Bool
uaContainsHeadlessMarker ua =
  let lower = asciiToLower ua
  in any (`BS.isInfixOf` lower) headlessPatterns

uaIsCommonBrowser :: ByteString -> Bool
uaIsCommonBrowser ua =
  let lower = asciiToLower ua
      hits = length (filter (`BS.isInfixOf` lower) commonBrowserMarkers)
  in hits >= commonBrowserMarkerThreshold

pathDepth :: ByteString -> Int
pathDepth path =
  let segments = filter (not . BS.null) (BC.split '/' path)
  in length segments

pathHasSuspiciousExtension :: ByteString -> Bool
pathHasSuspiciousExtension path =
  let lower = asciiToLower path
  in any (`BS.isSuffixOf` lower) suspiciousPathExtensions

methodIsIdempotent :: ByteString -> Bool
methodIsIdempotent m = m `elem` idempotentMethods

secFetchModeIsValid :: ByteString -> Bool
secFetchModeIsValid v = asciiToLower v `elem` secFetchModeValidValues

secFetchTripleIsCoherent
  :: Maybe ByteString
  -> Maybe ByteString
  -> Maybe ByteString
  -> Bool
secFetchTripleIsCoherent mSite mMode mDest =
  case (asciiToLower <$> mSite, asciiToLower <$> mMode, asciiToLower <$> mDest) of
    (Just site, Just mode, Just dest) ->
         site `elem` secFetchSiteValidValues
      && mode `elem` secFetchModeValidValues
      && tripleConsistent site mode dest
    _ -> False
  where
    tripleConsistent site mode dest
      | site == "none" && mode /= "navigate" = False
      | mode == "navigate" && dest `notElem` secFetchDestNavigationValues = False
      | mode == "cors" && site == "none" = False
      | mode == "websocket" && dest /= "websocket" && dest /= "empty" = False
      | otherwise = True

uaPlatformConsistency :: Maybe ByteString -> Maybe ByteString -> Double
uaPlatformConsistency mUa mPlatform = case mPlatform of
  Nothing -> 1.0
  Just p ->
    let lowerP = asciiToLower (stripQuotes p)
    in case mUa of
         Nothing -> 0.0
         Just ua ->
           let lowerUa = asciiToLower ua
               markers = platformUaMarkers lowerP
           in if null markers
                then 0.0
                else
                  if any (`BS.isInfixOf` lowerUa) markers
                    then 1.0
                    else 0.0

stripQuotes :: ByteString -> ByteString
stripQuotes bs =
  let trimmed = BS.dropWhile (== quoteByte) (BS.reverse bs)
      back    = BS.reverse trimmed
  in BS.dropWhile (== quoteByte) back
  where
    quoteByte = 34

platformUaMarkers :: ByteString -> [ByteString]
platformUaMarkers p
  | p == "windows"  = ["windows nt"]
  | p == "macos"    = ["mac os x", "macintosh"]
  | p == "linux"    = ["linux", "x11"]
  | p == "android"  = ["android"]
  | p == "ios"      = ["iphone", "ipad", "ipod"]
  | p == "chrome os" = ["cros"]
  | p == "chromeos" = ["cros"]
  | otherwise = []

acceptIsWildcard :: Maybe ByteString -> Bool
acceptIsWildcard mAccept = case mAccept of
  Nothing -> False
  Just v  ->
    let trimmed = BS.dropWhile (== spaceByte)
                $ BS.reverse
                $ BS.dropWhile (== spaceByte)
                $ BS.reverse v
    in trimmed == "*/*"
  where
    spaceByte = 32

headerOrderIsCanonicalBrowser :: [(CI ByteString, ByteString)] -> Bool
headerOrderIsCanonicalBrowser headers =
  let projected = filter (`elem` headerOrderTrackedNames)
                $ map fst headers
      chromeMatch  = projected == filter (`elem` projected) chromeHeaderCanonicalOrder
                       && all (`elem` projected) requiredCore
      firefoxMatch = projected == filter (`elem` projected) firefoxHeaderCanonicalOrder
                       && all (`elem` projected) requiredCore
  in chromeMatch || firefoxMatch
  where
    requiredCore = ["host", "user-agent", "accept"]

data FeatureContext = FeatureContext
  { fcGeoInfo          :: !GeoInfo
  , fcAsnConcentration :: !Double
  } deriving (Eq, Show)

emptyFeatureContext :: FeatureContext
emptyFeatureContext = FeatureContext
  { fcGeoInfo = emptyGeoInfo
  , fcAsnConcentration = 0.0
  }

data FeatureVector = FeatureVector
  { fMissingAcceptLanguage   :: {-# UNPACK #-} !Double
  , fMissingUserAgent        :: {-# UNPACK #-} !Double
  , fMissingAcceptEncoding   :: {-# UNPACK #-} !Double
  , fMissingReferer          :: {-# UNPACK #-} !Double
  , fHasCookie               :: {-# UNPACK #-} !Double
  , fHasSecChUa              :: {-# UNPACK #-} !Double
  , fHeaderCount             :: {-# UNPACK #-} !Double
  , fUaSecChConsistent       :: {-# UNPACK #-} !Double
  , fUaBotKeyword            :: {-# UNPACK #-} !Double
  , fUaHeadless              :: {-# UNPACK #-} !Double
  , fUaCommonBrowser         :: {-# UNPACK #-} !Double
  , fUaLength                :: {-# UNPACK #-} !Double
  , fPathDepth               :: {-# UNPACK #-} !Double
  , fPathEntropy             :: {-# UNPACK #-} !Double
  , fSuspiciousPathExt       :: {-# UNPACK #-} !Double
  , fQueryParamCount         :: {-# UNPACK #-} !Double
  , fMethodIdempotent        :: {-# UNPACK #-} !Double
  , fFlaggedAsn              :: {-# UNPACK #-} !Double
  , fAsnConcentration        :: {-# UNPACK #-} !Double
  , fCountryUnknown          :: {-# UNPACK #-} !Double
  , fMissingSecFetchSite     :: {-# UNPACK #-} !Double
  , fSecFetchModeValid       :: {-# UNPACK #-} !Double
  , fSecFetchContextCoherent :: {-# UNPACK #-} !Double
  , fChUaPlatformPresent     :: {-# UNPACK #-} !Double
  , fChUaPlatformConsistent  :: {-# UNPACK #-} !Double
  , fAcceptIsWildcard        :: {-# UNPACK #-} !Double
  , fAcceptValueLength       :: {-# UNPACK #-} !Double
  , fHeaderOrderCanonical    :: {-# UNPACK #-} !Double
  } deriving (Eq, Show)

featureVectorLength :: Int
featureVectorLength = 28

featureNames :: [Text]
featureNames =
  [ "missing_accept_language"
  , "missing_user_agent"
  , "missing_accept_encoding"
  , "missing_referer"
  , "has_cookie"
  , "has_sec_ch_ua"
  , "header_count"
  , "ua_sec_ch_consistent"
  , "ua_bot_keyword"
  , "ua_headless"
  , "ua_common_browser"
  , "ua_length"
  , "path_depth"
  , "path_entropy"
  , "suspicious_path_ext"
  , "query_param_count"
  , "method_idempotent"
  , "flagged_asn"
  , "asn_concentration"
  , "country_unknown"
  , "missing_sec_fetch_site"
  , "sec_fetch_mode_valid"
  , "sec_fetch_context_coherent"
  , "ch_ua_platform_present"
  , "ch_ua_platform_consistent"
  , "accept_is_wildcard"
  , "accept_value_length"
  , "header_order_canonical"
  ]

featureVectorToList :: FeatureVector -> [Double]
featureVectorToList FeatureVector{..} =
  [ fMissingAcceptLanguage
  , fMissingUserAgent
  , fMissingAcceptEncoding
  , fMissingReferer
  , fHasCookie
  , fHasSecChUa
  , fHeaderCount
  , fUaSecChConsistent
  , fUaBotKeyword
  , fUaHeadless
  , fUaCommonBrowser
  , fUaLength
  , fPathDepth
  , fPathEntropy
  , fSuspiciousPathExt
  , fQueryParamCount
  , fMethodIdempotent
  , fFlaggedAsn
  , fAsnConcentration
  , fCountryUnknown
  , fMissingSecFetchSite
  , fSecFetchModeValid
  , fSecFetchContextCoherent
  , fChUaPlatformPresent
  , fChUaPlatformConsistent
  , fAcceptIsWildcard
  , fAcceptValueLength
  , fHeaderOrderCanonical
  ]

featureVectorToVector :: FeatureVector -> Vector Double
featureVectorToVector = VU.fromList . featureVectorToList

boolToDouble :: Bool -> Double
boolToDouble True = 1.0
boolToDouble False = 0.0

extractFeatures :: FeatureContext -> Request -> FeatureVector
extractFeatures FeatureContext{..} req =
  let !headers       = requestHeaders req
      !path          = rawPathInfo req
      !method        = requestMethod req
      !mAcceptLang   = lookup acceptLanguageHeader headers
      !mUserAgent    = lookup userAgentHeader headers
      !mAcceptEnc    = lookup acceptEncodingHeader headers
      !mReferer      = lookup refererHeader headers
      !mCookie       = lookup cookieHeader headers
      !mSecChUa      = lookup secChUaHeader headers
      !mSecChPlat    = lookup secChUaPlatformHeader headers
      !mSecFetchSite = lookup secFetchSiteHeader headers
      !mSecFetchMode = lookup secFetchModeHeader headers
      !mSecFetchDest = lookup secFetchDestHeader headers
      !mAccept       = lookup acceptHeader headers
      !uaBytes       = fromMaybe BS.empty mUserAgent
      !uaLen         = BS.length uaBytes
      !depth         = pathDepth path
      !entropy       = shannonEntropyBytes path
      !queryCount    = length (queryString req)
      !geo           = fcGeoInfo
      !acceptLen     = maybe 0 BS.length mAccept
      !modeValid     = maybe False secFetchModeIsValid mSecFetchMode
  in FeatureVector
       { fMissingAcceptLanguage   = boolToDouble (not (isJust mAcceptLang))
       , fMissingUserAgent        = boolToDouble (not (isJust mUserAgent))
       , fMissingAcceptEncoding   = boolToDouble (not (isJust mAcceptEnc))
       , fMissingReferer          = boolToDouble (not (isJust mReferer))
       , fHasCookie               = boolToDouble (isJust mCookie)
       , fHasSecChUa              = boolToDouble (isJust mSecChUa)
       , fHeaderCount             = normalizedRatio (length headers) headerCountCap
       , fUaSecChConsistent       = uaSecChConsistency mUserAgent mSecChUa
       , fUaBotKeyword            = boolToDouble
                                      (maybe False uaContainsBotKeyword mUserAgent)
       , fUaHeadless              = boolToDouble
                                      (maybe False uaContainsHeadlessMarker mUserAgent)
       , fUaCommonBrowser         = boolToDouble
                                      (maybe False uaIsCommonBrowser mUserAgent)
       , fUaLength                = normalizedRatio uaLen userAgentLengthCap
       , fPathDepth               = normalizedRatio depth pathDepthCap
       , fPathEntropy             = clamp01 (entropy / pathEntropyMax)
       , fSuspiciousPathExt       = boolToDouble (pathHasSuspiciousExtension path)
       , fQueryParamCount         = normalizedRatio queryCount queryParamCountCap
       , fMethodIdempotent        = boolToDouble (methodIsIdempotent method)
       , fFlaggedAsn              = boolToDouble (giFlaggedAsn geo)
       , fAsnConcentration        = clamp01 fcAsnConcentration
       , fCountryUnknown          = boolToDouble
                                      (case giCountryISO geo of
                                         Nothing -> True
                                         Just _ -> False)
       , fMissingSecFetchSite     = boolToDouble (not (isJust mSecFetchSite))
       , fSecFetchModeValid       = boolToDouble modeValid
       , fSecFetchContextCoherent = boolToDouble
                                      (secFetchTripleIsCoherent
                                         mSecFetchSite mSecFetchMode mSecFetchDest)
       , fChUaPlatformPresent     = boolToDouble (isJust mSecChPlat)
       , fChUaPlatformConsistent  = uaPlatformConsistency mUserAgent mSecChPlat
       , fAcceptIsWildcard        = boolToDouble (acceptIsWildcard mAccept)
       , fAcceptValueLength       = normalizedRatio acceptLen acceptValueLengthCap
       , fHeaderOrderCanonical    = boolToDouble
                                      (headerOrderIsCanonicalBrowser headers)
       }
