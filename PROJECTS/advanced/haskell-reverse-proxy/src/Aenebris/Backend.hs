{-
©AngelaMos | 2026
Backend.hs
-}
{-# LANGUAGE RecordWildCards #-}

module Aenebris.Backend
  ( BackendState(..)
  , RuntimeBackend(..)
  , createRuntimeBackend
  , isHealthy
  , trackConnection
  , getConnectionCount
  , getCurrentWeight
  , transitionToUnhealthy
  , transitionToRecovering
  , transitionToHealthy
  , recordFailure
  , recordSuccess
  ) where

import Aenebris.Config (Server(..))
import Control.Concurrent.STM
import Control.Exception (bracket_)
import Control.Monad (when)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)

initialActiveConnections :: Int
initialActiveConnections = 0

initialCurrentWeight :: Int
initialCurrentWeight = 0

initialFailureCount :: Int
initialFailureCount = 0

initialSuccessCount :: Int
initialSuccessCount = 0

initialMetricCount :: Int
initialMetricCount = 0

data BackendState
  = Healthy
  | Unhealthy
  | Recovering
  deriving (Eq, Show)

data RuntimeBackend = RuntimeBackend
  { rbServerId             :: !Int
  , rbHost                 :: !Text
  , rbWeight               :: !Int
  , rbActiveConnections    :: !(TVar Int)
  , rbCurrentWeight        :: !(TVar Int)
  , rbHealthState          :: !(TVar BackendState)
  , rbConsecutiveFailures  :: !(TVar Int)
  , rbConsecutiveSuccesses :: !(TVar Int)
  , rbLastHealthCheck      :: !(TVar (Maybe UTCTime))
  , rbTotalRequests        :: !(TVar Int)
  , rbTotalFailures        :: !(TVar Int)
  }

instance Show RuntimeBackend where
  show rb = "RuntimeBackend {id="
              ++ show (rbServerId rb)
              ++ ", host="
              ++ show (rbHost rb)
              ++ ", weight="
              ++ show (rbWeight rb)
              ++ "}"

instance Eq RuntimeBackend where
  rb1 == rb2 = rbServerId rb1 == rbServerId rb2

createRuntimeBackend :: Int -> Server -> IO RuntimeBackend
createRuntimeBackend serverId Server{..} = atomically $
  RuntimeBackend serverId serverHost serverWeight
    <$> newTVar initialActiveConnections
    <*> newTVar initialCurrentWeight
    <*> newTVar Healthy
    <*> newTVar initialFailureCount
    <*> newTVar initialSuccessCount
    <*> newTVar Nothing
    <*> newTVar initialMetricCount
    <*> newTVar initialMetricCount

isHealthy :: RuntimeBackend -> STM Bool
isHealthy rb = (== Healthy) <$> readTVar (rbHealthState rb)

trackConnection :: RuntimeBackend -> IO a -> IO a
trackConnection rb action =
  bracket_
    (atomically $ do
      modifyTVar' (rbActiveConnections rb) (+ 1)
      modifyTVar' (rbTotalRequests rb) (+ 1))
    (atomically $ modifyTVar' (rbActiveConnections rb) (subtract 1))
    action

getConnectionCount :: RuntimeBackend -> STM Int
getConnectionCount rb = readTVar (rbActiveConnections rb)

getCurrentWeight :: RuntimeBackend -> STM Int
getCurrentWeight rb = readTVar (rbCurrentWeight rb)

transitionToUnhealthy :: RuntimeBackend -> STM ()
transitionToUnhealthy rb = do
  writeTVar (rbHealthState rb) Unhealthy
  writeTVar (rbConsecutiveFailures rb) initialFailureCount
  writeTVar (rbConsecutiveSuccesses rb) initialSuccessCount

transitionToRecovering :: RuntimeBackend -> STM ()
transitionToRecovering rb = do
  writeTVar (rbHealthState rb) Recovering
  writeTVar (rbConsecutiveSuccesses rb) 1

transitionToHealthy :: RuntimeBackend -> STM ()
transitionToHealthy rb = do
  writeTVar (rbHealthState rb) Healthy
  writeTVar (rbConsecutiveFailures rb) initialFailureCount
  writeTVar (rbConsecutiveSuccesses rb) initialSuccessCount

recordFailure :: RuntimeBackend -> Int -> STM ()
recordFailure rb maxFailures = do
  modifyTVar' (rbTotalFailures rb) (+ 1)
  state <- readTVar (rbHealthState rb)
  failures <- readTVar (rbConsecutiveFailures rb)
  case state of
    Healthy -> do
      let newFailures = failures + 1
      writeTVar (rbConsecutiveFailures rb) newFailures
      when (newFailures >= maxFailures) $
        transitionToUnhealthy rb
    Recovering ->
      transitionToUnhealthy rb
    Unhealthy ->
      pure ()

recordSuccess :: RuntimeBackend -> Int -> STM ()
recordSuccess rb recoveryAttempts = do
  state <- readTVar (rbHealthState rb)
  successes <- readTVar (rbConsecutiveSuccesses rb)
  case state of
    Healthy ->
      writeTVar (rbConsecutiveFailures rb) initialFailureCount
    Unhealthy ->
      transitionToRecovering rb
    Recovering -> do
      let newSuccesses = successes + 1
      writeTVar (rbConsecutiveSuccesses rb) newSuccesses
      when (newSuccesses >= recoveryAttempts) $
        transitionToHealthy rb
