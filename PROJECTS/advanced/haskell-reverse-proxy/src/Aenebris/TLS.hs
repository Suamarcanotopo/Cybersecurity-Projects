{-
©AngelaMos | 2026
TLS.hs
-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Aenebris.TLS
  ( TLSSettings
  , createTLSSettings
  , createSNISettings
  , validateCertificate
  , CertificateError(..)
  , strongCipherSuites
  ) where

import Control.Exception (SomeException, try)
import qualified Data.ByteString.Lazy as LBS
import Data.Default.Class (def)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.X509 (SignedCertificate)
import Data.X509.File (readSignedObject)
import qualified Network.TLS as TLS
import qualified Network.TLS.Extra.Cipher as Cipher
import Network.Wai.Handler.WarpTLS
import System.Directory (doesFileExist)
import System.IO (hPutStrLn, stderr)

httpsRequiredMessage :: LBS.ByteString
httpsRequiredMessage = "This server requires HTTPS"

data CertificateError
  = CertFileNotFound FilePath
  | KeyFileNotFound FilePath
  | InvalidCertificate FilePath String
  | InvalidKey FilePath String
  deriving (Show, Eq)

createTLSSettings
  :: FilePath
  -> FilePath
  -> IO (Either CertificateError TLSSettings)
createTLSSettings certFile keyFile = do
  certExists <- doesFileExist certFile
  keyExists  <- doesFileExist keyFile
  if not certExists
    then pure (Left (CertFileNotFound certFile))
    else if not keyExists
      then pure (Left (KeyFileNotFound keyFile))
      else do
        result <- try $ TLS.credentialLoadX509 certFile keyFile
        case result of
          Left (err :: SomeException) ->
            pure (Left (InvalidCertificate certFile (show err)))
          Right (Left err) ->
            pure (Left (InvalidCertificate certFile err))
          Right (Right _) ->
            pure (Right (configureTLS certFile keyFile))

configureTLS :: FilePath -> FilePath -> TLSSettings
configureTLS certFile keyFile = (tlsSettings certFile keyFile)
  { tlsAllowedVersions = [TLS.TLS13, TLS.TLS12]
  , tlsCiphers = strongCipherSuites
  , onInsecure = DenyInsecure httpsRequiredMessage
  }

createSNISettings
  :: [(Text, FilePath, FilePath)]
  -> FilePath
  -> FilePath
  -> IO (Either CertificateError TLSSettings)
createSNISettings domains defaultCert defaultKey = do
  defaultCertOk <- doesFileExist defaultCert
  defaultKeyOk  <- doesFileExist defaultKey
  if not defaultCertOk
    then pure (Left (CertFileNotFound defaultCert))
    else if not defaultKeyOk
      then pure (Left (KeyFileNotFound defaultKey))
      else do
        validations <- mapM validateDomainCert domains
        case sequence validations of
          Left err -> pure (Left err)
          Right _ -> pure (Right (configureSNI domains defaultCert defaultKey))

configureSNI
  :: [(Text, FilePath, FilePath)]
  -> FilePath
  -> FilePath
  -> TLSSettings
configureSNI domains defaultCert defaultKey =
  let baseTLS = tlsSettings defaultCert defaultKey
  in baseTLS
       { tlsAllowedVersions = [TLS.TLS13, TLS.TLS12]
       , tlsCiphers = strongCipherSuites
       , onInsecure = DenyInsecure httpsRequiredMessage
       , tlsServerHooks = def
           { TLS.onServerNameIndication = \mHostname -> case mHostname of
               Nothing -> credentialsOrDefault defaultCert defaultKey
               Just hostname ->
                 sniCallback domains defaultCert defaultKey hostname
           }
       }

validateDomainCert
  :: (Text, FilePath, FilePath) -> IO (Either CertificateError ())
validateDomainCert (_domain, certFile, keyFile) = do
  certExists <- doesFileExist certFile
  keyExists  <- doesFileExist keyFile
  if not certExists
    then pure (Left (CertFileNotFound certFile))
    else if not keyExists
      then pure (Left (KeyFileNotFound keyFile))
      else pure (Right ())

sniCallback
  :: [(Text, FilePath, FilePath)]
  -> FilePath
  -> FilePath
  -> String
  -> IO TLS.Credentials
sniCallback domains defaultCert defaultKey hostname =
  let domainMap :: Map Text (FilePath, FilePath)
      domainMap = Map.fromList [(d, (c, k)) | (d, c, k) <- domains]
  in case Map.lookup (T.pack hostname) domainMap of
       Nothing -> credentialsOrDefault defaultCert defaultKey
       Just (certFile, keyFile) ->
         credentialsOrDefault certFile keyFile

credentialsOrDefault :: FilePath -> FilePath -> IO TLS.Credentials
credentialsOrDefault certFile keyFile = do
  result <- TLS.credentialLoadX509 certFile keyFile
  case result of
    Left err -> do
      hPutStrLn stderr $
        "TLS: failed to load credential at "
        <> certFile <> " (" <> err <> "); SNI handler returns empty credentials"
      pure (TLS.Credentials [])
    Right credential ->
      pure (TLS.Credentials [credential])

validateCertificate
  :: FilePath -> IO (Either CertificateError [SignedCertificate])
validateCertificate certFile = do
  exists <- doesFileExist certFile
  if not exists
    then pure (Left (CertFileNotFound certFile))
    else do
      result <- try $ readSignedObject certFile
      case result of
        Left (err :: SomeException) ->
          pure (Left (InvalidCertificate certFile (show err)))
        Right certs ->
          pure (Right certs)

strongCipherSuites :: [TLS.Cipher]
strongCipherSuites =
  [ Cipher.cipher13_AES_128_GCM_SHA256
  , Cipher.cipher13_AES_256_GCM_SHA384
  , Cipher.cipher13_CHACHA20_POLY1305_SHA256
  , Cipher.cipher_ECDHE_RSA_WITH_AES_128_GCM_SHA256
  , Cipher.cipher_ECDHE_RSA_WITH_AES_256_GCM_SHA384
  , Cipher.cipher_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
  , Cipher.cipher_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
  , Cipher.cipher_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
  , Cipher.cipher_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256
  ]
