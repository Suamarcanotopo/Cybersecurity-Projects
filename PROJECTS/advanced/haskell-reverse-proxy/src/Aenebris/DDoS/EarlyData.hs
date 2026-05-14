{-
©AngelaMos | 2026
EarlyData.hs
-}
{-# LANGUAGE OverloadedStrings #-}

module Aenebris.DDoS.EarlyData
  ( earlyDataGuard
  , isIdempotent
  , isEarlyData
  , status425
  ) where

import Data.ByteString (ByteString)
import Network.HTTP.Types (Status, mkStatus, methodGet, methodHead)
import Network.Wai
  ( Middleware
  , Request
  , requestHeaders
  , requestMethod
  , responseLBS
  )

status425 :: Status
status425 = mkStatus 425 "Too Early"

isIdempotent :: Request -> Bool
isIdempotent req = requestMethod req == methodGet || requestMethod req == methodHead

isEarlyData :: Request -> Bool
isEarlyData req = lookup "Early-Data" (requestHeaders req) == Just earlyDataHeaderValue

earlyDataHeaderValue :: ByteString
earlyDataHeaderValue = "1"

earlyDataGuard :: Middleware
earlyDataGuard app req respond
  | isEarlyData req && not (isIdempotent req) =
      respond $ responseLBS status425
        [ ("Content-Type", "text/plain; charset=utf-8")
        , ("Cache-Control", "no-store")
        ]
        "425 Too Early: non-idempotent method in 0-RTT data (RFC 8470)"
  | otherwise = app req respond
