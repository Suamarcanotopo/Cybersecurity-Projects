{-
©AngelaMos | 2026
MemoryShed.hs
-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

module Aenebris.DDoS.MemoryShed
  ( MemoryShed
  , MemoryShedConfig(..)
  , defaultMemoryShedConfig
  , newMemoryShed
  , startMemoryShedPoller
  , memoryShedMiddleware
  , isShedding
  , updateShedding
  , defaultPollIntervalMicros
  , defaultHighWaterFraction
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async)
import Control.Monad (forever)
import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, readTVar, writeTVar)
import Data.Word (Word64)
import GHC.Stats (RTSStats(..), GCDetails(..), getRTSStats, getRTSStatsEnabled)
import Network.HTTP.Types (status503)
import Network.Wai (Middleware, responseLBS)

defaultPollIntervalMicros :: Int
defaultPollIntervalMicros = 1_000_000

defaultHighWaterFraction :: Double
defaultHighWaterFraction = 0.70

data MemoryShedConfig = MemoryShedConfig
  { mscHeapBudgetBytes :: !Word64
  , mscHighWaterFraction :: !Double
  , mscPollIntervalMicros :: !Int
  } deriving (Show, Eq)

defaultMemoryShedConfig :: Word64 -> MemoryShedConfig
defaultMemoryShedConfig budget = MemoryShedConfig
  { mscHeapBudgetBytes = budget
  , mscHighWaterFraction = defaultHighWaterFraction
  , mscPollIntervalMicros = defaultPollIntervalMicros
  }

newtype MemoryShed = MemoryShed { msFlag :: TVar Bool }

newMemoryShed :: IO MemoryShed
newMemoryShed = MemoryShed <$> newTVarIO False

isShedding :: MemoryShed -> STM Bool
isShedding = readTVar . msFlag

updateShedding :: MemoryShed -> Bool -> STM ()
updateShedding (MemoryShed tv) = writeTVar tv

startMemoryShedPoller :: MemoryShedConfig -> MemoryShed -> IO (Async ())
startMemoryShedPoller cfg shed = async $ do
  enabled <- getRTSStatsEnabled
  if not enabled
    then pure ()
    else forever $ do
      threadDelay (mscPollIntervalMicros cfg)
      stats <- getRTSStats
      let live = gcdetails_live_bytes (gc stats)
          threshold = floor (fromIntegral (mscHeapBudgetBytes cfg) * mscHighWaterFraction cfg :: Double) :: Word64
          shedNow = live > threshold
      atomically (updateShedding shed shedNow)

memoryShedMiddleware :: MemoryShed -> Middleware
memoryShedMiddleware shed app req respond = do
  shedding <- atomically (isShedding shed)
  if shedding
    then respond $ responseLBS status503
      [ ("Content-Type", "text/plain; charset=utf-8")
      , ("Retry-After", "1")
      ]
      "503 Service Unavailable: memory pressure, shedding load"
    else app req respond
