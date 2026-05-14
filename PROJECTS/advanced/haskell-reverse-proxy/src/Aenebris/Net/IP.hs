{-
©AngelaMos | 2026
IP.hs
-}
{-# LANGUAGE OverloadedStrings #-}

module Aenebris.Net.IP
  ( sockAddrToIPBytes
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS8
import Data.List (intercalate)
import Network.Socket
  ( HostAddress6
  , SockAddr(..)
  , hostAddress6ToTuple
  , hostAddressToTuple
  )
import Numeric (showHex)
import Text.Printf (printf)

ipv4Format :: String
ipv4Format = "%d.%d.%d.%d"

ipv6Separator :: String
ipv6Separator = ":"

unixSocketPrefix :: String
unixSocketPrefix = "unix:"

sockAddrToIPBytes :: SockAddr -> ByteString
sockAddrToIPBytes (SockAddrInet _ ha) =
  let (a, b, c, d) = hostAddressToTuple ha
  in BS8.pack (printf ipv4Format a b c d)
sockAddrToIPBytes (SockAddrInet6 _ _ ha6 _) = renderIPv6 ha6
sockAddrToIPBytes (SockAddrUnix p) = BS8.pack (unixSocketPrefix <> p)

renderIPv6 :: HostAddress6 -> ByteString
renderIPv6 ha =
  let (a, b, c, d, e, f, g, h) = hostAddress6ToTuple ha
      parts = [a, b, c, d, e, f, g, h]
  in BS8.pack (intercalate ipv6Separator (map (`showHex` "") parts))
