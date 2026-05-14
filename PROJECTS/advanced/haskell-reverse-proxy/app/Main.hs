{-
©AngelaMos | 2026
Main.hs
-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Aenebris.Config
import Aenebris.Connection
  ( defaultTimeoutConfig
  , microsPerSecond
  , tcUpstreamReadSeconds
  )
import Aenebris.Proxy
import Network.HTTP.Client
  ( ManagerSettings(..)
  , defaultManagerSettings
  , newManager
  , responseTimeoutMicro
  )
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

defaultConfigPath :: FilePath
defaultConfigPath = "config.yaml"

main :: IO ()
main = do
  args <- getArgs
  let configPath = case args of
        (path:_) -> path
        []       -> defaultConfigPath

  putStrLn $ "Loading configuration from: " ++ configPath

  result <- loadConfig configPath
  case result of
    Left err -> do
      hPutStrLn stderr "ERROR: Failed to load configuration"
      hPutStrLn stderr err
      exitFailure

    Right config -> case validateConfig config of
      Left err -> do
        hPutStrLn stderr "ERROR: Invalid configuration"
        hPutStrLn stderr err
        exitFailure

      Right () -> do
        putStrLn "Configuration loaded and validated successfully"
        let upstreamMicros = tcUpstreamReadSeconds defaultTimeoutConfig
                           * microsPerSecond
            managerSettings = defaultManagerSettings
              { managerResponseTimeout = responseTimeoutMicro upstreamMicros
              }
        manager    <- newManager managerSettings
        proxyState <- initProxyState config manager
        startProxy proxyState
