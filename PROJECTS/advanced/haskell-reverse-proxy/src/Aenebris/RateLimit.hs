{-
©AngelaMos | 2026
RateLimit.hs
-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Aenebris.RateLimit
  ( RateLimiter
  , RateSpec(..)
  , Decision(..)
  , Key
  , parseRateSpec
  , createRateLimiter
  , checkLimit
  , rateLimitMiddleware
  , clientIPKey
  , pathClassKey
  , defaultBurstMultiplier
  , bucketPruneThreshold
  , bucketPruneAge
  ) where

import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , newTVarIO
  , readTVar
  , writeTVar
  )
import Aenebris.Net.IP (sockAddrToIPBytes)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS8
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as TR
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import Network.HTTP.Types (status429)
import Network.Wai
  ( Middleware
  , Request
  , rawPathInfo
  , remoteHost
  , responseLBS
  )

secondsPerMinute :: Double
secondsPerMinute = 60

secondsPerHour :: Double
secondsPerHour = 3600

defaultBurstMultiplier :: Double
defaultBurstMultiplier = 1.0

bucketPruneThreshold :: Int
bucketPruneThreshold = 10000

bucketPruneAge :: POSIXTime
bucketPruneAge = 300

data RateSpec = RateSpec
  { rsCapacity :: !Double
  , rsRefillPerSec :: !Double
  } deriving (Show, Eq)

data Bucket = Bucket
  { bkTokens :: !Double
  , bkLastRefill :: !POSIXTime
  } deriving (Show, Eq)

type Key = (ByteString, ByteString)

data RateLimiter = RateLimiter
  { rlBuckets :: TVar (Map Key Bucket)
  , rlSpec :: !RateSpec
  }

data Decision
  = Allowed !Double
  | Denied !Double
  deriving (Show, Eq)

parseRateSpec :: Text -> Maybe RateSpec
parseRateSpec spec =
  case T.splitOn "/" (T.strip spec) of
    [countTxt, unitTxt] -> do
      count <- parsePositiveInt countTxt
      perSec <- unitToPerSecond (T.toLower (T.strip unitTxt))
      let capacity = fromIntegral count
      Just RateSpec
        { rsCapacity = capacity * defaultBurstMultiplier
        , rsRefillPerSec = capacity * perSec
        }
    _ -> Nothing
  where
    parsePositiveInt :: Text -> Maybe Int
    parsePositiveInt t = case TR.decimal (T.strip t) of
      Right (n, rest) | T.null rest && n > 0 -> Just n
      _ -> Nothing

    unitToPerSecond :: Text -> Maybe Double
    unitToPerSecond u
      | u == "s" || u == "sec" || u == "second" = Just 1
      | u == "m" || u == "min" || u == "minute" = Just (1 / secondsPerMinute)
      | u == "h" || u == "hr" || u == "hour" = Just (1 / secondsPerHour)
      | otherwise = Nothing

createRateLimiter :: RateSpec -> IO RateLimiter
createRateLimiter spec = do
  tv <- newTVarIO Map.empty
  pure RateLimiter { rlBuckets = tv, rlSpec = spec }

checkLimit :: RateLimiter -> Key -> POSIXTime -> STM Decision
checkLimit RateLimiter{..} key now = do
  buckets <- readTVar rlBuckets
  let RateSpec cap rate = rlSpec
      current = Map.findWithDefault (Bucket cap now) key buckets
      elapsed = realToFrac (now - bkLastRefill current) :: Double
      refilled = min cap (bkTokens current + max 0 elapsed * rate)
  if refilled >= 1
    then do
      let next = Bucket (refilled - 1) now
      writeTVar rlBuckets $! pruneIfLarge now (Map.insert key next buckets)
      pure (Allowed (refilled - 1))
    else do
      let next = Bucket refilled now
          retry = if rate > 0 then (1 - refilled) / rate else 0
      writeTVar rlBuckets $! pruneIfLarge now (Map.insert key next buckets)
      pure (Denied retry)

pruneIfLarge :: POSIXTime -> Map Key Bucket -> Map Key Bucket
pruneIfLarge now m
  | Map.size m < bucketPruneThreshold = m
  | otherwise = Map.filter (\b -> now - bkLastRefill b <= bucketPruneAge) m

rateLimitMiddleware :: RateLimiter -> Middleware
rateLimitMiddleware rl app req respond = do
  now <- getPOSIXTime
  let key = (clientIPKey req, pathClassKey req)
  decision <- atomically (checkLimit rl key now)
  case decision of
    Allowed _remaining -> app req respond
    Denied retry -> respond $ responseLBS status429
      [ ("Content-Type", "text/plain; charset=utf-8")
      , ("X-RateLimit-Limit", intBS (floor (rsCapacity (rlSpec rl)) :: Int))
      , ("X-RateLimit-Remaining", "0")
      , ("X-RateLimit-Reset", intBS (ceilingInt retry))
      , ("Retry-After", intBS (ceilingInt retry))
      ]
      "Too Many Requests"
  where
    ceilingInt x = max 1 (ceiling x :: Int)
    intBS n = BS8.pack (show n)

clientIPKey :: Request -> ByteString
clientIPKey = sockAddrToIPBytes . remoteHost

pathClassKey :: Request -> ByteString
pathClassKey req =
  case BS8.split '/' (rawPathInfo req) of
    (_ : seg : _) | not (BS8.null seg) -> "/" <> seg
    _ -> "/"
