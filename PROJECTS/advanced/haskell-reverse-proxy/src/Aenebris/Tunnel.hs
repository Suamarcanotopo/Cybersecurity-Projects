{-
©AngelaMos | 2026
Tunnel.hs
-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Aenebris.Tunnel
  ( ConnectError(..)
  , connectToBackend
  , parseHostPort
  , parseUpgradeStatus
  , tunnelWebSocket
  , streamResponse
  , bidirectionalCopy
  ) where

import Control.Concurrent.Async (race_)
import Control.Exception
  ( SomeException
  , bracketOnError
  , finally
  , try
  )
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import Data.CaseInsensitive (original)
import Data.Text (Text)
import qualified Data.Text as T
import Network.Socket (Socket)
import qualified Network.Socket as Socket
import qualified Network.Socket.ByteString as SocketBS
import Network.Wai
  ( Request
  , rawPathInfo
  , rawQueryString
  , requestHeaders
  , requestMethod
  )
import System.IO (hPutStrLn, stderr)
import System.Timeout (timeout)

defaultBackendPort :: Int
defaultBackendPort = 80

upgradeRecvChunkBytes :: Int
upgradeRecvChunkBytes = 4_096

maxUpgradeHeaderBytes :: Int
maxUpgradeHeaderBytes = 16_384

tunnelRecvChunkBytes :: Int
tunnelRecvChunkBytes = 65_536

connectTimeoutSeconds :: Int
connectTimeoutSeconds = 5

upgradeIdleSeconds :: Int
upgradeIdleSeconds = 30

microsPerSecond :: Int
microsPerSecond = 1_000_000

upgradeStatusSwitching :: Int
upgradeStatusSwitching = 101

badGatewayResponseLine :: ByteString
badGatewayResponseLine = "HTTP/1.1 502 Bad Gateway\r\n\r\n"

upgradeTerminator :: ByteString
upgradeTerminator = "\r\n\r\n"

httpHeaderLineEnd :: ByteString
httpHeaderLineEnd = "\r\n"

httpVersionAndCrlf :: ByteString
httpVersionAndCrlf = " HTTP/1.1\r\n"

httpFieldSeparator :: ByteString
httpFieldSeparator = ": "

requestPathSeparator :: ByteString
requestPathSeparator = " "

data ConnectError
  = ResolutionFailed !String !Int
  | ConnectTimeout !String !Int
  | ConnectFailed !String !Int !String
  deriving (Eq, Show)

tunnelWebSocket
  :: Request
  -> Text
  -> (ByteString -> IO ())
  -> IO ByteString
  -> IO ()
tunnelWebSocket clientReq backendHost clientSend clientRecv = do
  hPutStrLn stderr $ "[WS] Initiating tunnel to " ++ T.unpack backendHost
  let (host, port) = parseHostPort backendHost
  outcome <- try $ do
    eSock <- connectToBackend host port
    case eSock of
      Left err -> do
        hPutStrLn stderr $ "[WS] Connection failed: " ++ show err
        clientSend badGatewayResponseLine
      Right sock ->
        runUpgrade clientReq clientSend clientRecv sock
          `finally` Socket.close sock
  case outcome of
    Left (e :: SomeException) ->
      hPutStrLn stderr $ "[WS] Tunnel error: " ++ show e
    Right () ->
      hPutStrLn stderr "[WS] Tunnel closed"

runUpgrade
  :: Request
  -> (ByteString -> IO ())
  -> IO ByteString
  -> Socket
  -> IO ()
runUpgrade clientReq clientSend clientRecv sock = do
  sendUpgradeRequest sock clientReq
  mResponse <- timeout
    (upgradeIdleSeconds * microsPerSecond)
    (receiveUpgradeResponse sock)
  case mResponse of
    Nothing -> do
      hPutStrLn stderr "[WS] Upgrade response timed out"
      clientSend badGatewayResponseLine
    Just upgradeResponse ->
      dispatchUpgrade sock clientSend clientRecv upgradeResponse

dispatchUpgrade
  :: Socket
  -> (ByteString -> IO ())
  -> IO ByteString
  -> ByteString
  -> IO ()
dispatchUpgrade sock clientSend clientRecv upgradeResponse =
  case parseUpgradeStatus upgradeResponse of
    Just code | code == upgradeStatusSwitching -> do
      hPutStrLn stderr "[WS] Backend accepted upgrade (101)"
      clientSend upgradeResponse
      bidirectionalCopy
        clientRecv clientSend
        (SocketBS.recv sock tunnelRecvChunkBytes)
        (SocketBS.sendAll sock)
    Just code -> do
      hPutStrLn stderr $ "[WS] Backend rejected upgrade: " ++ show code
      clientSend upgradeResponse
    Nothing -> do
      hPutStrLn stderr "[WS] Invalid upgrade response"
      clientSend badGatewayResponseLine

bidirectionalCopy
  :: IO ByteString
  -> (ByteString -> IO ())
  -> IO ByteString
  -> (ByteString -> IO ())
  -> IO ()
bidirectionalCopy clientRecv clientSend backendRecv backendSend = do
  hPutStrLn stderr "[TUNNEL] Starting bidirectional copy"
  race_
    (copyLoop "client->backend" clientRecv backendSend)
    (copyLoop "backend->client" backendRecv clientSend)
  hPutStrLn stderr "[TUNNEL] Bidirectional copy ended"

copyLoop :: String -> IO ByteString -> (ByteString -> IO ()) -> IO ()
copyLoop name recv send = go
  where
    go = do
      chunk <- recv
      if BS.null chunk
        then hPutStrLn stderr $ "[TUNNEL] " ++ name ++ ": connection closed"
        else do
          send chunk
          go

streamResponse
  :: (ByteString -> IO ())
  -> IO ByteString
  -> IO ()
streamResponse clientSend backendRecv = do
  hPutStrLn stderr "[STREAM] Starting streaming response"
  go
  where
    go = do
      chunk <- backendRecv
      if BS.null chunk
        then hPutStrLn stderr "[STREAM] Backend closed"
        else do
          clientSend chunk
          go

parseHostPort :: Text -> (String, Int)
parseHostPort hostPort =
  case T.splitOn ":" hostPort of
    [host, portStr] ->
      case reads (T.unpack portStr) of
        [(port, "")] -> (T.unpack host, port)
        _ -> (T.unpack host, defaultBackendPort)
    [host] -> (T.unpack host, defaultBackendPort)
    _ -> (T.unpack hostPort, defaultBackendPort)

connectToBackend :: String -> Int -> IO (Either ConnectError Socket)
connectToBackend host port = do
  resolution <- try $ Socket.getAddrInfo
    (Just Socket.defaultHints { Socket.addrSocketType = Socket.Stream })
    (Just host)
    (Just (show port))
  case resolution of
    Left (_ :: SomeException) -> pure (Left (ResolutionFailed host port))
    Right [] -> pure (Left (ResolutionFailed host port))
    Right (addr : _) -> attemptConnect host port addr

attemptConnect
  :: String -> Int -> Socket.AddrInfo -> IO (Either ConnectError Socket)
attemptConnect host port addr =
  bracketOnError
    (Socket.socket
      (Socket.addrFamily addr)
      Socket.Stream
      Socket.defaultProtocol)
    Socket.close
    $ \sock -> do
        mConnect <- timeout
          (connectTimeoutSeconds * microsPerSecond)
          (try (Socket.connect sock (Socket.addrAddress addr)))
        case mConnect of
          Nothing -> do
            Socket.close sock
            pure (Left (ConnectTimeout host port))
          Just (Left (e :: SomeException)) -> do
            Socket.close sock
            pure (Left (ConnectFailed host port (show e)))
          Just (Right ()) ->
            pure (Right sock)

sendUpgradeRequest :: Socket -> Request -> IO ()
sendUpgradeRequest sock req =
  let method      = requestMethod req
      path        = rawPathInfo req <> rawQueryString req
      headers     = requestHeaders req
      requestLine = method <> requestPathSeparator <> path <> httpVersionAndCrlf
      headerLines = BS.concat
        [ original name <> httpFieldSeparator <> value <> httpHeaderLineEnd
        | (name, value) <- headers
        ]
      fullRequest = requestLine <> headerLines <> httpHeaderLineEnd
  in SocketBS.sendAll sock fullRequest

receiveUpgradeResponse :: Socket -> IO ByteString
receiveUpgradeResponse sock = go BS.empty
  where
    go !acc
      | upgradeTerminator `BS.isInfixOf` acc = pure acc
      | BS.length acc >= maxUpgradeHeaderBytes = pure acc
      | otherwise = do
          chunk <- SocketBS.recv sock upgradeRecvChunkBytes
          if BS.null chunk
            then pure acc
            else go (acc <> chunk)

parseUpgradeStatus :: ByteString -> Maybe Int
parseUpgradeStatus response = case BS8.lines response of
  [] -> Nothing
  (firstLine : _) -> case BS8.words firstLine of
    (_ : codeBS : _) -> case reads (BS8.unpack codeBS) of
      [(code, "")] -> Just code
      _            -> Nothing
    _ -> Nothing
