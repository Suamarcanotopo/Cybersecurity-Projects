{-
©AngelaMos | 2026
Security.hs
-}
{-# LANGUAGE OverloadedStrings #-}

module Aenebris.Middleware.Security
  ( addSecurityHeaders
  , SecurityLevel(..)
  , SecurityConfig(..)
  , defaultSecurityConfig
  , strictSecurityConfig
  , testingSecurityConfig
  ) where

import Data.ByteString (ByteString)
import qualified Data.CaseInsensitive as CI
import Data.Maybe (catMaybes)
import Network.HTTP.Types (Header, ResponseHeaders)
import Network.Wai (Middleware, mapResponseHeaders)

data SecurityLevel
  = Testing
  | Production
  | Strict
  deriving (Show, Eq)

data SecurityConfig = SecurityConfig
  { scHSTS                :: !(Maybe ByteString)
  , scCSP                 :: !(Maybe ByteString)
  , scFrameOptions        :: !(Maybe ByteString)
  , scContentTypeOptions  :: !Bool
  , scReferrerPolicy      :: !(Maybe ByteString)
  , scPermissionsPolicy   :: !(Maybe ByteString)
  , scXSSProtection       :: !(Maybe ByteString)
  , scExpectCT            :: !(Maybe ByteString)
  , scServerHeader        :: !(Maybe ByteString)
  , scRemovePoweredBy     :: !Bool
  } deriving (Show, Eq)

testingSecurityConfig :: SecurityConfig
testingSecurityConfig = SecurityConfig
  { scHSTS                = Just "max-age=300"
  , scCSP                 = Just "default-src 'self' 'unsafe-inline' 'unsafe-eval'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'"
  , scFrameOptions        = Just "SAMEORIGIN"
  , scContentTypeOptions  = True
  , scReferrerPolicy      = Just "strict-origin-when-cross-origin"
  , scPermissionsPolicy   = Just "geolocation=(), microphone=(), camera=()"
  , scXSSProtection       = Just "1; mode=block"
  , scExpectCT            = Nothing
  , scServerHeader        = Just "Aenebris/0.1.0"
  , scRemovePoweredBy     = True
  }

defaultSecurityConfig :: SecurityConfig
defaultSecurityConfig = SecurityConfig
  { scHSTS                = Just "max-age=2592000; includeSubDomains"
  , scCSP                 = Just "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; connect-src 'self'; frame-ancestors 'none'"
  , scFrameOptions        = Just "DENY"
  , scContentTypeOptions  = True
  , scReferrerPolicy      = Just "strict-origin-when-cross-origin"
  , scPermissionsPolicy   = Just "geolocation=(), microphone=(), camera=(), payment=(), usb=(), magnetometer=(), gyroscope=(), accelerometer=()"
  , scXSSProtection       = Just "1; mode=block"
  , scExpectCT            = Just "max-age=86400, enforce"
  , scServerHeader        = Just "Aenebris"
  , scRemovePoweredBy     = True
  }

strictSecurityConfig :: SecurityConfig
strictSecurityConfig = SecurityConfig
  { scHSTS                = Just "max-age=63072000; includeSubDomains; preload"
  , scCSP                 = Just "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'; upgrade-insecure-requests"
  , scFrameOptions        = Just "DENY"
  , scContentTypeOptions  = True
  , scReferrerPolicy      = Just "no-referrer"
  , scPermissionsPolicy   = Just "geolocation=(), microphone=(), camera=(), payment=(), usb=(), magnetometer=(), gyroscope=(), accelerometer=(), bluetooth=(), display-capture=(), document-domain=()"
  , scXSSProtection       = Just "1; mode=block"
  , scExpectCT            = Just "max-age=86400, enforce"
  , scServerHeader        = Nothing
  , scRemovePoweredBy     = True
  }

addSecurityHeaders :: SecurityConfig -> Middleware
addSecurityHeaders config app req respond =
  app req $ \res ->
    respond $ mapResponseHeaders (addHeaders config) res

addHeaders :: SecurityConfig -> ResponseHeaders -> ResponseHeaders
addHeaders config headers =
  let cleaned = if scRemovePoweredBy config
                  then filter (not . isPoweredBy) headers
                  else headers
      newHeaders = catMaybes
        [ fmap (\v -> ("Strict-Transport-Security", v)) (scHSTS config)
        , fmap (\v -> ("Content-Security-Policy", v)) (scCSP config)
        , fmap (\v -> ("X-Frame-Options", v)) (scFrameOptions config)
        , if scContentTypeOptions config
            then Just ("X-Content-Type-Options", "nosniff")
            else Nothing
        , fmap (\v -> ("Referrer-Policy", v)) (scReferrerPolicy config)
        , fmap (\v -> ("Permissions-Policy", v)) (scPermissionsPolicy config)
        , fmap (\v -> ("X-XSS-Protection", v)) (scXSSProtection config)
        , fmap (\v -> ("Expect-CT", v)) (scExpectCT config)
        ]
      serverHeader = case scServerHeader config of
        Just v  -> [("Server", v)]
        Nothing -> []
      withoutServer = filter (not . isServerHeader) cleaned
  in withoutServer ++ newHeaders ++ serverHeader

isPoweredBy :: Header -> Bool
isPoweredBy (name, _) = CI.mk name == CI.mk "X-Powered-By"

isServerHeader :: Header -> Bool
isServerHeader (name, _) = CI.mk name == CI.mk "Server"
