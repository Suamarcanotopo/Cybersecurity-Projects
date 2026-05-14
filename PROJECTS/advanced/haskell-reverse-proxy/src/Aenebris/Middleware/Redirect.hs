{-
©AngelaMos | 2026
Redirect.hs
-}
{-# LANGUAGE OverloadedStrings #-}

module Aenebris.Middleware.Redirect
  ( httpsRedirect
  , httpsRedirectWithPort
  ) where

import qualified Data.ByteString.Char8 as BS
import Data.Maybe (fromMaybe)
import Network.HTTP.Types (hLocation, status301)
import Network.Wai
  ( Middleware
  , isSecure
  , rawPathInfo
  , rawQueryString
  , requestHeaderHost
  , responseLBS
  )

defaultHostFallback :: BS.ByteString
defaultHostFallback = "localhost"

httpsScheme :: BS.ByteString
httpsScheme = "https://"

standardHttpsPort :: Int
standardHttpsPort = 443

redirectBody :: BS.ByteString
redirectBody = "Redirecting to HTTPS"

httpsRedirect :: Middleware
httpsRedirect = httpsRedirectWithPort Nothing

httpsRedirectWithPort :: Maybe Int -> Middleware
httpsRedirectWithPort httpsPort app req respond
  | isSecure req = app req respond
  | otherwise = do
      let hostHeader = fromMaybe defaultHostFallback (requestHeaderHost req)
          host = case httpsPort of
            Nothing                          -> hostHeader
            Just port | port == standardHttpsPort -> hostHeader
            Just port -> hostHeader <> ":" <> BS.pack (show port)
          path        = rawPathInfo req
          query       = rawQueryString req
          redirectUrl = httpsScheme <> host <> path <> query
      respond $ responseLBS
        status301
        [(hLocation, redirectUrl)]
        (BS.fromStrict redirectBody)
