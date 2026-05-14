{-
©AngelaMos | 2026
HealthCheck.hs
-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Aenebris.HealthCheck
  ( HealthCheckConfig(..)
  , defaultHealthCheckConfig
  , startHealthChecker
  , stopHealthChecker
  , performHealthCheck
  ) where

import Aenebris.Backend
import Aenebris.Connection (httpOkStatusCode, microsPerSecond)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Monad (forever, zipWithM_)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Network.HTTP.Client
import Network.HTTP.Types.Status (statusCode)
import System.Timeout (timeout)

defaultHealthCheckIntervalSeconds :: Int
defaultHealthCheckIntervalSeconds = 10

defaultHealthCheckTimeoutSeconds :: Int
defaultHealthCheckTimeoutSeconds = 2

defaultHealthCheckMaxFailures :: Int
defaultHealthCheckMaxFailures = 3

defaultHealthCheckRecoveryAttempts :: Int
defaultHealthCheckRecoveryAttempts = 2

defaultHealthCheckEndpoint :: Text
defaultHealthCheckEndpoint = "/health"

data HealthCheckConfig = HealthCheckConfig
  { hcInterval         :: !Int
  , hcTimeout          :: !Int
  , hcEndpoint         :: !Text
  , hcMaxFailures      :: !Int
  , hcRecoveryAttempts :: !Int
  }

defaultHealthCheckConfig :: HealthCheckConfig
defaultHealthCheckConfig = HealthCheckConfig
  { hcInterval         = defaultHealthCheckIntervalSeconds
  , hcTimeout          = defaultHealthCheckTimeoutSeconds
  , hcEndpoint         = defaultHealthCheckEndpoint
  , hcMaxFailures      = defaultHealthCheckMaxFailures
  , hcRecoveryAttempts = defaultHealthCheckRecoveryAttempts
  }

startHealthChecker
  :: Manager -> HealthCheckConfig -> [RuntimeBackend] -> IO (Async ())
startHealthChecker manager config backends =
  async (healthCheckLoop manager config backends)

stopHealthChecker :: Async () -> IO ()
stopHealthChecker = cancel

healthCheckLoop :: Manager -> HealthCheckConfig -> [RuntimeBackend] -> IO ()
healthCheckLoop manager config backends = forever $ do
  results <- mapConcurrently (performHealthCheck manager config) backends
  atomically $ zipWithM_ (updateBackendState config) backends results
  threadDelay (hcInterval config * microsPerSecond)

performHealthCheck :: Manager -> HealthCheckConfig -> RuntimeBackend -> IO Bool
performHealthCheck manager config backend = do
  let url = "http://" ++ T.unpack (rbHost backend) ++ T.unpack (hcEndpoint config)
  result <- timeout (hcTimeout config * microsPerSecond) $ do
    req <- parseRequest url
    response <- httpLbs req manager
    pure (statusCode (responseStatus response) == httpOkStatusCode)
  now <- getCurrentTime
  atomically $ writeTVar (rbLastHealthCheck backend) (Just now)
  pure $ case result of
    Just True -> True
    _         -> False

updateBackendState :: HealthCheckConfig -> RuntimeBackend -> Bool -> STM ()
updateBackendState config backend healthy =
  if healthy
    then recordSuccess backend (hcRecoveryAttempts config)
    else recordFailure backend (hcMaxFailures config)
