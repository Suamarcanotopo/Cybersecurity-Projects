{-
©AngelaMos | 2026
IPJail.hs
-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

module Aenebris.DDoS.IPJail
  ( IPJail
  , JailedEntry(..)
  , IPJailConfig(..)
  , defaultIPJailConfig
  , newIPJail
  , jail
  , isJailed
  , purgeExpired
  , startJailSweeper
  , ipJailMiddleware
  , defaultJailCooldown
  , defaultSweepIntervalMicros
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async)
import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , modifyTVar'
  , newTVarIO
  , readTVar
  )
import Control.Monad (forever)
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import Network.HTTP.Types (status403)
import Network.Wai (Middleware, responseLBS)

import Aenebris.RateLimit (clientIPKey)

defaultJailCooldown :: POSIXTime
defaultJailCooldown = 300

defaultSweepIntervalMicros :: Int
defaultSweepIntervalMicros = 30_000_000

data JailedEntry = JailedEntry
  { jeExpiresAt :: !POSIXTime
  , jeReason :: !ByteString
  } deriving (Show, Eq)

data IPJailConfig = IPJailConfig
  { ijcDefaultCooldown :: !POSIXTime
  , ijcSweepIntervalMicros :: !Int
  } deriving (Show, Eq)

defaultIPJailConfig :: IPJailConfig
defaultIPJailConfig = IPJailConfig
  { ijcDefaultCooldown = defaultJailCooldown
  , ijcSweepIntervalMicros = defaultSweepIntervalMicros
  }

newtype IPJail = IPJail { ijMap :: TVar (Map ByteString JailedEntry) }

newIPJail :: IO IPJail
newIPJail = IPJail <$> newTVarIO Map.empty

jail :: IPJail -> ByteString -> POSIXTime -> ByteString -> POSIXTime -> STM ()
jail (IPJail tv) ip cooldown reason now =
  modifyTVar' tv (Map.insert ip entry)
  where
    entry = JailedEntry { jeExpiresAt = now + cooldown, jeReason = reason }

isJailed :: IPJail -> ByteString -> POSIXTime -> STM (Maybe JailedEntry)
isJailed (IPJail tv) ip now = do
  m <- readTVar tv
  case Map.lookup ip m of
    Just e | jeExpiresAt e > now -> pure (Just e)
    _ -> pure Nothing

purgeExpired :: IPJail -> POSIXTime -> STM Int
purgeExpired (IPJail tv) now = do
  m <- readTVar tv
  let (stale, fresh) = Map.partition (\e -> jeExpiresAt e <= now) m
  modifyTVar' tv (const fresh)
  pure (Map.size stale)

startJailSweeper :: IPJailConfig -> IPJail -> IO (Async ())
startJailSweeper cfg j = async $ forever $ do
  threadDelay (ijcSweepIntervalMicros cfg)
  now <- getPOSIXTime
  _ <- atomically (purgeExpired j now)
  pure ()

ipJailMiddleware :: IPJail -> Middleware
ipJailMiddleware j app req respond = do
  now <- getPOSIXTime
  let ip = clientIPKey req
  jailed <- atomically (isJailed j ip now)
  case jailed of
    Just _entry -> respond $ responseLBS status403
      [ ("Content-Type", "text/plain; charset=utf-8")
      , ("Cache-Control", "no-store")
      ]
      "403 Forbidden: source address is temporarily restricted"
    Nothing -> app req respond
