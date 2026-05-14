{-
©AngelaMos | 2026
Honeypot.hs
-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Aenebris.Honeypot
  ( TrapPattern(..)
  , HoneypotAction(..)
  , HoneypotConfig(..)
  , HoneypotConfigYaml(..)
  , defaultTrapPatterns
  , defaultHoneypotConfig
  , defaultHoneypotCooldown
  , defaultLabyrinthPrefix
  , defaultLabyrinthFanout
  , honeypotResponseHeader
  , robotsResponseHeader
  , matchTrap
  , isAllowed
  , honeypotMiddleware
  , labyrinthBody
  , robotsTxtBody
  , parseHoneypotAction
  , buildHoneypotConfig
  ) where

import Aenebris.DDoS.IPJail (IPJail, jail)
import Aenebris.RateLimit (clientIPKey)
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Data.Aeson (FromJSON(..), withObject, (.!=), (.:?))
import Data.Bits (shiftR, xor)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as LBS
import Data.CaseInsensitive (CI)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import Data.Word (Word64)
import GHC.Generics (Generic)
import Network.HTTP.Types (status200, status404)
import Network.Wai
  ( Middleware
  , Response
  , rawPathInfo
  , requestMethod
  , responseLBS
  )
import Numeric (showHex)

data TrapPattern
  = TrapExact !ByteString
  | TrapPrefix !ByteString
  deriving (Eq, Show)

data HoneypotAction
  = HoneypotJail
  | HoneypotLog
  | HoneypotLabyrinth
  deriving (Eq, Show)

data HoneypotConfig = HoneypotConfig
  { hpPatterns :: ![TrapPattern]
  , hpAction :: !HoneypotAction
  , hpJailCooldown :: !POSIXTime
  , hpResponseDelayMicros :: !(Maybe Int)
  , hpAllowedIPs :: ![ByteString]
  , hpServeRobotsTxt :: !Bool
  , hpLabyrinthFanout :: !Int
  } deriving (Eq, Show)

defaultHoneypotCooldown :: POSIXTime
defaultHoneypotCooldown = 3600

defaultLabyrinthPrefix :: ByteString
defaultLabyrinthPrefix = "/_labyrinth/"

defaultLabyrinthFanout :: Int
defaultLabyrinthFanout = 24

defaultTrapPatterns :: [TrapPattern]
defaultTrapPatterns =
  [ TrapExact "/.env"
  , TrapExact "/.env.local"
  , TrapExact "/.env.production"
  , TrapExact "/.env.backup"
  , TrapExact "/wp-login.php"
  , TrapExact "/wp-admin"
  , TrapExact "/xmlrpc.php"
  , TrapExact "/phpmyadmin"
  , TrapExact "/pma"
  , TrapExact "/myadmin"
  , TrapExact "/administrator"
  , TrapExact "/admin/config.php"
  , TrapExact "/server-status"
  , TrapExact "/server-info"
  , TrapExact "/.DS_Store"
  , TrapExact "/.htaccess"
  , TrapExact "/.htpasswd"
  , TrapExact "/backup.sql"
  , TrapExact "/db.sql"
  , TrapExact "/dump.sql"
  , TrapExact "/database.sql"
  , TrapExact "/config.php.bak"
  , TrapExact "/web.config"
  , TrapExact "/sftp-config.json"
  , TrapPrefix "/.git/"
  , TrapPrefix "/.svn/"
  , TrapPrefix "/.hg/"
  , TrapPrefix "/.aws/"
  , TrapPrefix "/.ssh/"
  , TrapPrefix "/.vscode/"
  , TrapPrefix "/.idea/"
  , TrapPrefix "/wp-content/plugins/"
  , TrapPrefix "/wp-includes/"
  , TrapPrefix "/vendor/phpunit/"
  , TrapPrefix "/cgi-bin/"
  , TrapPrefix "/actuator/"
  , TrapPrefix "/_ignition/"
  , TrapPrefix "/druid/indexer/"
  , TrapPrefix "/jenkins/script"
  , TrapPrefix "/solr/admin/"
  , TrapPrefix "/manager/html"
  , TrapPrefix "/console/login"
  , TrapPrefix defaultLabyrinthPrefix
  ]

defaultHoneypotConfig :: HoneypotConfig
defaultHoneypotConfig = HoneypotConfig
  { hpPatterns = defaultTrapPatterns
  , hpAction = HoneypotJail
  , hpJailCooldown = defaultHoneypotCooldown
  , hpResponseDelayMicros = Nothing
  , hpAllowedIPs = []
  , hpServeRobotsTxt = True
  , hpLabyrinthFanout = defaultLabyrinthFanout
  }

data HoneypotConfigYaml = HoneypotConfigYaml
  { hpyEnabled :: !Bool
  , hpyAction :: !Text
  , hpyCooldownSeconds :: !(Maybe Int)
  , hpyResponseDelayMillis :: !(Maybe Int)
  , hpyExtraExact :: ![Text]
  , hpyExtraPrefix :: ![Text]
  , hpyUseDefaults :: !Bool
  , hpyAllowedIPs :: ![Text]
  , hpyServeRobotsTxt :: !Bool
  , hpyLabyrinthFanout :: !(Maybe Int)
  } deriving (Eq, Show, Generic)

instance FromJSON HoneypotConfigYaml where
  parseJSON = withObject "HoneypotConfig" $ \v -> HoneypotConfigYaml
    <$> v .:? "enabled" .!= True
    <*> v .:? "action" .!= "jail"
    <*> v .:? "cooldown_seconds"
    <*> v .:? "response_delay_millis"
    <*> v .:? "extra_exact_paths" .!= []
    <*> v .:? "extra_prefix_paths" .!= []
    <*> v .:? "use_default_traps" .!= True
    <*> v .:? "allowed_ips" .!= []
    <*> v .:? "serve_robots_txt" .!= True
    <*> v .:? "labyrinth_fanout"

parseHoneypotAction :: Text -> HoneypotAction
parseHoneypotAction t = case T.toLower t of
  "jail" -> HoneypotJail
  "labyrinth" -> HoneypotLabyrinth
  "log" -> HoneypotLog
  _ -> HoneypotLog

buildHoneypotConfig :: Maybe HoneypotConfigYaml -> Maybe HoneypotConfig
buildHoneypotConfig Nothing = Nothing
buildHoneypotConfig (Just y)
  | not (hpyEnabled y) = Nothing
  | otherwise = Just HoneypotConfig
      { hpPatterns = basePatterns <> extraExact <> extraPrefix
      , hpAction = parseHoneypotAction (hpyAction y)
      , hpJailCooldown = maybe defaultHoneypotCooldown fromIntegral (hpyCooldownSeconds y)
      , hpResponseDelayMicros = fmap (\ms -> ms * 1000) (hpyResponseDelayMillis y)
      , hpAllowedIPs = map TE.encodeUtf8 (hpyAllowedIPs y)
      , hpServeRobotsTxt = hpyServeRobotsTxt y
      , hpLabyrinthFanout = fromMaybe defaultLabyrinthFanout (hpyLabyrinthFanout y)
      }
  where
    basePatterns = if hpyUseDefaults y then defaultTrapPatterns else []
    extraExact = [TrapExact (TE.encodeUtf8 t) | t <- hpyExtraExact y]
    extraPrefix = [TrapPrefix (TE.encodeUtf8 t) | t <- hpyExtraPrefix y]

honeypotResponseHeader :: CI ByteString
honeypotResponseHeader = "x-aenebris-honeypot"

robotsResponseHeader :: CI ByteString
robotsResponseHeader = "x-aenebris-robots"

matchTrap :: ByteString -> [TrapPattern] -> Maybe TrapPattern
matchTrap _ [] = Nothing
matchTrap path (p : rest) = case p of
  TrapExact e | e == path -> Just p
  TrapPrefix pr | BS.isPrefixOf pr path -> Just p
  _ -> matchTrap path rest

isAllowed :: ByteString -> [ByteString] -> Bool
isAllowed = elem

isLabyrinthPath :: ByteString -> Bool
isLabyrinthPath = BS.isPrefixOf defaultLabyrinthPrefix

trapLabel :: TrapPattern -> ByteString
trapLabel (TrapExact e) = e
trapLabel (TrapPrefix p) = p <> "*"

honeypotMiddleware :: HoneypotConfig -> Maybe IPJail -> Middleware
honeypotMiddleware cfg@HoneypotConfig{..} mJail app req respond
  | hpServeRobotsTxt && requestMethod req == "GET"
                     && rawPathInfo req == "/robots.txt" =
      respond (robotsResponse cfg)
  | otherwise = case matchTrap (rawPathInfo req) hpPatterns of
      Nothing -> app req respond
      Just trap -> do
        now <- getPOSIXTime
        let ip = clientIPKey req
            label = trapLabel trap
            allowed = isAllowed ip hpAllowedIPs
        case (hpAction, allowed, mJail) of
          (HoneypotJail, False, Just j) ->
            atomically (jail j ip hpJailCooldown ("honeypot:" <> label) now)
          (HoneypotLabyrinth, False, Just j) ->
            atomically (jail j ip hpJailCooldown ("honeypot:" <> label) now)
          _ -> pure ()
        maybe (pure ()) threadDelay hpResponseDelayMicros
        respond (trapResponse cfg (rawPathInfo req) label allowed)

trapResponse :: HoneypotConfig -> ByteString -> ByteString -> Bool -> Response
trapResponse HoneypotConfig{..} path label allowed
  | hpAction == HoneypotLabyrinth || isLabyrinthPath path =
      responseLBS status200
        [ ("Content-Type", "text/html; charset=utf-8")
        , ("Cache-Control", "no-store, no-cache, must-revalidate")
        , ("Pragma", "no-cache")
        , ("X-Robots-Tag", "noindex, nofollow")
        , (honeypotResponseHeader, marker "labyrinth")
        ]
        (labyrinthBody path hpLabyrinthFanout)
  | otherwise =
      responseLBS status404
        [ ("Content-Type", "text/plain; charset=utf-8")
        , ("Cache-Control", "no-store")
        , (honeypotResponseHeader, marker "trap")
        ]
        "404 Not Found"
  where
    marker kind =
      kind <> "=" <> label <> (if allowed then " allow=1" else "")

robotsResponse :: HoneypotConfig -> Response
robotsResponse cfg =
  responseLBS status200
    [ ("Content-Type", "text/plain; charset=utf-8")
    , ("Cache-Control", "public, max-age=3600")
    , (robotsResponseHeader, "generated")
    ]
    (LBS.fromStrict (robotsTxtBody cfg))

robotsTxtBody :: HoneypotConfig -> ByteString
robotsTxtBody HoneypotConfig{..} = BS.concat $
  [ "User-agent: *\n"
  , "# Honeypot trap paths. Disallow per RFC 9309. Visiting these\n"
  , "# paths is treated as a violation signal regardless of declared UA.\n"
  ] <> map disallowLine hpPatterns
  where
    disallowLine (TrapExact e) = "Disallow: " <> e <> "\n"
    disallowLine (TrapPrefix p) = "Disallow: " <> p <> "\n"

labyrinthBody :: ByteString -> Int -> LBS.ByteString
labyrinthBody requestPath fanout = LBS.fromStrict $ BS.concat
  [ "<!doctype html><html><head>"
  , "<title>", titleFor requestPath, "</title>"
  , "<meta name=\"robots\" content=\"noindex, nofollow\">"
  , "</head><body>"
  , "<h1>", titleFor requestPath, "</h1>"
  , "<p>Resource index. Pages may have moved; see the related entries below.</p>"
  , "<ul>", linkList, "</ul>"
  , "<p>Archive snapshots and historical mirrors are linked from the resource graph.</p>"
  , "</body></html>"
  ]
  where
    seed = fnv1a requestPath
    titleFor p = "Index " <> hexBytes (fnv1a p)
    linkList = BS.concat
      [ "<li><a href=\"" <> defaultLabyrinthPrefix
          <> hexBytes (mix seed i) <> "/"
          <> BC.pack (show i)
          <> "\">node-" <> BC.pack (show i) <> "</a></li>"
      | i <- [1 .. max 1 fanout]
      ]

mix :: Word64 -> Int -> Word64
mix s i = fnv1aStep s (fromIntegral (i `mod` 256))

fnv1a :: ByteString -> Word64
fnv1a = BS.foldl' (\h w -> fnv1aStep h (fromIntegral w)) fnvOffset
  where
    fnvOffset :: Word64
    fnvOffset = 14695981039346656037

fnv1aStep :: Word64 -> Word64 -> Word64
fnv1aStep h b = (h `xor` b) * fnvPrime
  where
    fnvPrime :: Word64
    fnvPrime = 1099511628211

hexBytes :: Word64 -> ByteString
hexBytes w = BC.pack (pad (showHex (w `shiftR` 32) "") 8)
  where
    pad s n
      | length s >= n = take n s
      | otherwise = replicate (n - length s) '0' <> s
