{-
©AngelaMos | 2026
LoadBalancer.hs
-}
{-# LANGUAGE RecordWildCards #-}

module Aenebris.LoadBalancer
  ( LoadBalancerStrategy(..)
  , LoadBalancer(..)
  , createLoadBalancer
  , selectBackend
  ) where

import Aenebris.Backend
import Control.Concurrent.STM
import Control.Monad (filterM, forM_)
import Data.IORef
import Data.List (maximumBy, minimumBy)
import Data.Ord (comparing)
import qualified Data.Vector as V
import Data.Vector (Vector, (!))

initialRoundRobinIndex :: Int
initialRoundRobinIndex = 0

data LoadBalancerStrategy
  = RoundRobin
  | LeastConnections
  | WeightedRoundRobin
  deriving (Eq, Show)

data LoadBalancer = LoadBalancer
  { lbBackends  :: !(Vector RuntimeBackend)
  , lbStrategy  :: !LoadBalancerStrategy
  , lbRRCounter :: !(IORef Int)
  }

createLoadBalancer
  :: LoadBalancerStrategy -> [RuntimeBackend] -> IO LoadBalancer
createLoadBalancer strategy backends = do
  counter <- newIORef initialRoundRobinIndex
  pure LoadBalancer
    { lbBackends  = V.fromList backends
    , lbStrategy  = strategy
    , lbRRCounter = counter
    }

selectBackend :: LoadBalancer -> IO (Maybe RuntimeBackend)
selectBackend lb = case lbStrategy lb of
  RoundRobin         -> selectRoundRobin lb
  LeastConnections   -> selectLeastConnections lb
  WeightedRoundRobin -> selectWeightedRR lb

selectRoundRobin :: LoadBalancer -> IO (Maybe RuntimeBackend)
selectRoundRobin LoadBalancer{..} = do
  let backends = lbBackends
      len      = V.length backends
  if len == 0
    then pure Nothing
    else do
      idx <- atomicModifyIORef' lbRRCounter $ \i ->
        let next = (i + 1) `mod` len
        in (next, i)
      findHealthyBackend backends idx len

findHealthyBackend
  :: Vector RuntimeBackend -> Int -> Int -> IO (Maybe RuntimeBackend)
findHealthyBackend backends startIdx totalBackends = go startIdx totalBackends
  where
    len = V.length backends
    go currentIdx remaining
      | remaining <= 0 = pure Nothing
      | otherwise = do
          let backend = backends ! currentIdx
          healthy <- atomically (isHealthy backend)
          if healthy
            then pure (Just backend)
            else go ((currentIdx + 1) `mod` len) (remaining - 1)

selectLeastConnections :: LoadBalancer -> IO (Maybe RuntimeBackend)
selectLeastConnections LoadBalancer{..} = atomically $ do
  let backends = V.toList lbBackends
  healthy <- filterM isHealthy backends
  case healthy of
    [] -> pure Nothing
    chosen -> do
      counts <- mapM getConnectionCount chosen
      let (_, minBackend) = minimumBy (comparing fst) (zip counts chosen)
      pure (Just minBackend)

selectWeightedRR :: LoadBalancer -> IO (Maybe RuntimeBackend)
selectWeightedRR LoadBalancer{..} = atomically $ do
  let backends = V.toList lbBackends
  healthy <- filterM isHealthy backends
  case healthy of
    [] -> pure Nothing
    chosen -> do
      forM_ chosen $ \rb ->
        modifyTVar' (rbCurrentWeight rb) (+ rbWeight rb)
      tagged <- mapM
        (\rb -> (\w -> (w, rb)) <$> readTVar (rbCurrentWeight rb))
        chosen
      let (_, picked) = maximumBy (comparing fst) tagged
          totalWeight = sum (map rbWeight chosen)
      modifyTVar' (rbCurrentWeight picked) (subtract totalWeight)
      pure (Just picked)
