{-
©AngelaMos | 2026
Connection.hs
-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Aenebris.Connection
  ( ConnectionState(..)
  , ConnectionType(..)
  , TimeoutConfig(..)
  , defaultTimeoutConfig
  , detectConnectionType
  , isWebSocketUpgrade
  , isStreamingResponse
  , getTimeout
  , microsPerSecond
  , httpOkStatusCode
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.CaseInsensitive as CI
import Data.Maybe (isJust)
import Network.HTTP.Types (HeaderName, Status, statusCode)

data ConnectionState
  = HttpRequest
  | HttpResponse
  | ProtocolUpgrade
  | TunnelMode
  | StreamingResponse
  deriving (Eq, Show)

data ConnectionType
  = RegularHttp
  | WebSocket
  | ServerSentEvents
  | ChunkedStream
  deriving (Eq, Show)

microsPerSecond :: Int
microsPerSecond = 1_000_000

httpOkStatusCode :: Int
httpOkStatusCode = 200

data TimeoutConfig = TimeoutConfig
  { tcHttpIdle           :: !Int
  , tcWebSocketTunnel    :: !Int
  , tcStreamingResponse  :: !Int
  , tcProxyPingInterval  :: !Int
  , tcPongTimeout        :: !Int
  , tcConnectTimeout     :: !Int
  , tcUpstreamReadSeconds :: !Int
  }

defaultTimeoutConfig :: TimeoutConfig
defaultTimeoutConfig = TimeoutConfig
  { tcHttpIdle            = 60
  , tcWebSocketTunnel     = 3600
  , tcStreamingResponse   = 3600
  , tcProxyPingInterval   = 30
  , tcPongTimeout         = 10
  , tcConnectTimeout      = 5
  , tcUpstreamReadSeconds = 30
  }

getTimeout :: TimeoutConfig -> ConnectionState -> Int
getTimeout TimeoutConfig{..} state = case state of
  HttpRequest -> tcHttpIdle
  HttpResponse -> tcHttpIdle
  ProtocolUpgrade -> tcHttpIdle
  TunnelMode -> tcWebSocketTunnel
  StreamingResponse -> tcStreamingResponse

detectConnectionType :: [(HeaderName, ByteString)] -> ConnectionType
detectConnectionType headers
  | isWebSocketUpgrade headers = WebSocket
  | otherwise = RegularHttp

isWebSocketUpgrade :: [(HeaderName, ByteString)] -> Bool
isWebSocketUpgrade headers =
  hasUpgradeWebsocket && hasConnectionUpgrade
  where
    hasUpgradeWebsocket = case lookup "Upgrade" headers of
      Just val -> CI.mk val == CI.mk ("websocket" :: ByteString)
      Nothing -> False

    hasConnectionUpgrade = case lookup "Connection" headers of
      Just val -> "upgrade" `BS.isInfixOf` CI.foldedCase (CI.mk val)
      Nothing -> False

isStreamingResponse :: Status -> [(HeaderName, ByteString)] -> Bool
isStreamingResponse status headers =
  isSSE || isChunkedWithoutLength || isUnknownLength
  where
    isSSE = case lookup "Content-Type" headers of
      Just ct -> "text/event-stream" `BS.isInfixOf` ct
      Nothing -> False

    isChunkedWithoutLength =
      hasTransferEncodingChunked && not hasContentLength

    hasTransferEncodingChunked = case lookup "Transfer-Encoding" headers of
      Just te -> "chunked" `BS.isInfixOf` CI.foldedCase (CI.mk te)
      Nothing -> False

    hasContentLength = isJust (lookup "Content-Length" headers)

    isUnknownLength =
      statusCode status == httpOkStatusCode
        && not hasContentLength
        && not hasTransferEncodingChunked
