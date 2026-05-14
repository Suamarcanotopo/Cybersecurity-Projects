{-
©AngelaMos | 2026
JA4H.hs
-}
{-# LANGUAGE OverloadedStrings #-}

module Aenebris.Fingerprint.JA4H
  ( JA4H(..)
  , computeJA4H
  , renderJA4H
  , ja4hMiddleware
  , ja4hHeaderName
  , methodCode
  , versionCode
  , acceptLanguagePrefix
  , parseCookieNames
  , parseCookiePairs
  , emptyHashPlaceholder
  ) where

import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteArray.Encoding (Base(Base16), convertToBase)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.CaseInsensitive (CI)
import qualified Data.CaseInsensitive as CI
import Data.Char (toLower, isAlphaNum)
import Data.List (sortBy, sortOn)
import Network.HTTP.Types (HttpVersion, http10, http11, http20, Method)
import Network.Wai
  ( Middleware
  , Request
  , requestHeaders
  , requestMethod
  , httpVersion
  , mapResponseHeaders
  )

data JA4H = JA4H
  { ja4hPartA :: !ByteString
  , ja4hHeaderHash :: !ByteString
  , ja4hCookieNameHash :: !ByteString
  , ja4hCookiePairHash :: !ByteString
  } deriving (Eq, Show)

emptyHashPlaceholder :: ByteString
emptyHashPlaceholder = "000000000000"

hashTruncated :: ByteString -> ByteString
hashTruncated input =
  let digest :: Digest SHA256
      digest = hash input
      hex = convertToBase Base16 digest :: ByteString
   in BS.take 12 hex

methodCode :: Method -> ByteString
methodCode m = case m of
  "GET" -> "ge"
  "POST" -> "po"
  "PUT" -> "pu"
  "DELETE" -> "de"
  "HEAD" -> "he"
  "OPTIONS" -> "op"
  "PATCH" -> "pa"
  "CONNECT" -> "co"
  _ -> "xx"

versionCode :: HttpVersion -> ByteString
versionCode v
  | v == http10 = "10"
  | v == http11 = "11"
  | v == http20 = "20"
  | otherwise = "00"

padTwo :: Int -> ByteString
padTwo n
  | n >= 99 = "99"
  | n < 10 = BC.pack ('0' : show n)
  | otherwise = BC.pack (show n)

cookieHeaderName :: CI ByteString
cookieHeaderName = "cookie"

refererHeaderName :: CI ByteString
refererHeaderName = "referer"

acceptLanguageHeaderName :: CI ByteString
acceptLanguageHeaderName = "accept-language"

acceptLanguagePrefix :: ByteString -> ByteString
acceptLanguagePrefix bs =
  let firstTag = BS.takeWhile (\c -> c /= 0x2c && c /= 0x3b && c /= 0x20) bs
      lowered = BC.map toLower firstTag
      cleaned = BC.filter (\c -> isAlphaNum c || c == '-') lowered
      stripped = BC.filter (/= '-') cleaned
      padded = stripped <> BC.replicate 4 '0'
   in BS.take 4 padded

parseCookieHeader :: ByteString -> [(ByteString, ByteString)]
parseCookieHeader raw =
  let pieces = BC.split ';' raw
      trimmed = map (BC.dropWhile (== ' ')) pieces
      nonEmpty = filter (not . BS.null) trimmed
   in map splitCookie nonEmpty
  where
    splitCookie piece =
      case BC.break (== '=') piece of
        (name, valueWithEq)
          | BS.null valueWithEq -> (name, BS.empty)
          | otherwise -> (name, BS.drop 1 valueWithEq)

parseCookieNames :: [(CI ByteString, ByteString)] -> [ByteString]
parseCookieNames hs =
  concatMap (map fst . parseCookieHeader . snd)
  $ filter ((== cookieHeaderName) . fst) hs

parseCookiePairs :: [(CI ByteString, ByteString)] -> [(ByteString, ByteString)]
parseCookiePairs hs =
  concatMap (parseCookieHeader . snd)
  $ filter ((== cookieHeaderName) . fst) hs

computeJA4H :: Request -> JA4H
computeJA4H req =
  let rawHeaders = requestHeaders req
      method = methodCode (requestMethod req)
      version = versionCode (httpVersion req)
      cookieFlag = if any ((== cookieHeaderName) . fst) rawHeaders then "c" else "n"
      refererFlag = if any ((== refererHeaderName) . fst) rawHeaders then "r" else "n"
      filteredHeaders =
        filter (\(k, _) -> k /= cookieHeaderName && k /= refererHeaderName) rawHeaders
      headerCount = padTwo (length filteredHeaders)
      langPrefix = maybe "0000" acceptLanguagePrefix
                 $ lookup acceptLanguageHeaderName rawHeaders
      partA = BS.concat [method, version, cookieFlag, refererFlag, headerCount, langPrefix]
      headerNameList = BS.intercalate "," (map (CI.original . fst) filteredHeaders)
      headerHash = hashTruncated headerNameList
      cookieNames = parseCookieNames rawHeaders
      cookieNameHash =
        if null cookieNames
          then emptyHashPlaceholder
          else hashTruncated (BS.intercalate "," (sortBy compare cookieNames))
      cookiePairs = parseCookiePairs rawHeaders
      cookiePairHash =
        if null cookiePairs
          then emptyHashPlaceholder
          else hashTruncated
             $ BS.intercalate ","
             $ map (\(n, v) -> n <> "=" <> v)
             $ sortOn fst cookiePairs
   in JA4H partA headerHash cookieNameHash cookiePairHash

renderJA4H :: JA4H -> ByteString
renderJA4H (JA4H a b c d) = BS.intercalate "_" [a, b, c, d]

ja4hHeaderName :: CI ByteString
ja4hHeaderName = "x-ja4h"

ja4hMiddleware :: Middleware
ja4hMiddleware app req respond =
  let fp = renderJA4H (computeJA4H req)
      addFp = mapResponseHeaders ((ja4hHeaderName, fp) :)
   in app req (respond . addFp)
