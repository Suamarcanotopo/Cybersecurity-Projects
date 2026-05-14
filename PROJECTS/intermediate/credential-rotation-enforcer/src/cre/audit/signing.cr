# ===================
# ©AngelaMos | 2026
# signing.cr
# ===================

require "openssl"
require "openssl/lib_crypto"

lib LibCrypto
  type EVP_PKEY = Void*

  fun evp_pkey_new_raw_private_key_cre = EVP_PKEY_new_raw_private_key(type : LibC::Int, e : Void*, key : UInt8*, keylen : LibC::SizeT) : EVP_PKEY
  fun evp_pkey_new_raw_public_key_cre = EVP_PKEY_new_raw_public_key(type : LibC::Int, e : Void*, key : UInt8*, keylen : LibC::SizeT) : EVP_PKEY
  fun evp_pkey_get_raw_public_key_cre = EVP_PKEY_get_raw_public_key(pkey : EVP_PKEY, pub : UInt8*, len : LibC::SizeT*) : LibC::Int
  fun evp_pkey_free_cre = EVP_PKEY_free(pkey : EVP_PKEY) : Void
  fun evp_digestsigninit_cre = EVP_DigestSignInit(ctx : EVP_MD_CTX, pctx : Void*, type : EVP_MD, e : Void*, pkey : EVP_PKEY) : LibC::Int
  fun evp_digestsign_cre = EVP_DigestSign(ctx : EVP_MD_CTX, sigret : UInt8*, siglen : LibC::SizeT*, tbs : UInt8*, tbslen : LibC::SizeT) : LibC::Int
  fun evp_digestverifyinit_cre = EVP_DigestVerifyInit(ctx : EVP_MD_CTX, pctx : Void*, type : EVP_MD, e : Void*, pkey : EVP_PKEY) : LibC::Int
  fun evp_digestverify_cre = EVP_DigestVerify(ctx : EVP_MD_CTX, sig : UInt8*, siglen : LibC::SizeT, tbs : UInt8*, tbslen : LibC::SizeT) : LibC::Int
end

module CRE::Audit::Signing
  NID_ED25519         = 1087
  ED25519_KEY_SIZE    =   32
  ED25519_SIG_SIZE    =   64
  ED25519_PUBKEY_SIZE =   32

  class Error < OpenSSL::Error; end

  class Ed25519Keypair
    getter version : Int32
    getter private_key : Bytes
    getter public_key : Bytes

    def initialize(@private_key : Bytes, @public_key : Bytes, @version : Int32)
      raise ArgumentError.new("private key must be 32 bytes") unless @private_key.size == ED25519_KEY_SIZE
      raise ArgumentError.new("public key must be 32 bytes") unless @public_key.size == ED25519_PUBKEY_SIZE
    end

    def self.generate(version : Int32 = 1) : Ed25519Keypair
      private_key = ::Random::Secure.random_bytes(ED25519_KEY_SIZE)
      pkey = LibCrypto.evp_pkey_new_raw_private_key_cre(NID_ED25519, Pointer(Void).null, private_key.to_unsafe, ED25519_KEY_SIZE.to_u64)
      raise Error.new("EVP_PKEY_new_raw_private_key failed") if pkey.null?
      begin
        pubkey_buf = Bytes.new(ED25519_PUBKEY_SIZE)
        len = ED25519_PUBKEY_SIZE.to_u64
        rc = LibCrypto.evp_pkey_get_raw_public_key_cre(pkey, pubkey_buf.to_unsafe, pointerof(len))
        raise Error.new("EVP_PKEY_get_raw_public_key failed (rc=#{rc})") unless rc == 1
        Ed25519Keypair.new(private_key, pubkey_buf, version)
      ensure
        LibCrypto.evp_pkey_free_cre(pkey)
      end
    end
  end

  class Ed25519Signer
    getter version : Int32

    def initialize(@private_key : Bytes, @version : Int32)
      raise ArgumentError.new("private key must be 32 bytes") unless @private_key.size == ED25519_KEY_SIZE
    end

    def self.from_keypair(kp : Ed25519Keypair) : Ed25519Signer
      Ed25519Signer.new(kp.private_key, kp.version)
    end

    def sign(message : Bytes) : Bytes
      pkey = LibCrypto.evp_pkey_new_raw_private_key_cre(NID_ED25519, Pointer(Void).null, @private_key.to_unsafe, ED25519_KEY_SIZE.to_u64)
      raise Error.new("EVP_PKEY_new_raw_private_key failed") if pkey.null?
      ctx = LibCrypto.evp_md_ctx_new
      raise Error.new("EVP_MD_CTX_new failed") if ctx.null?
      begin
        rc = LibCrypto.evp_digestsigninit_cre(ctx, Pointer(Void).null, Pointer(Void).null.as(LibCrypto::EVP_MD), Pointer(Void).null, pkey)
        raise Error.new("EVP_DigestSignInit failed (rc=#{rc})") unless rc == 1

        siglen = ED25519_SIG_SIZE.to_u64
        sig = Bytes.new(ED25519_SIG_SIZE)
        rc = LibCrypto.evp_digestsign_cre(ctx, sig.to_unsafe, pointerof(siglen), message.to_unsafe, message.size.to_u64)
        raise Error.new("EVP_DigestSign failed (rc=#{rc})") unless rc == 1

        sig
      ensure
        LibCrypto.evp_md_ctx_free(ctx)
        LibCrypto.evp_pkey_free_cre(pkey)
      end
    end
  end

  class Ed25519Verifier
    def initialize(@public_key : Bytes)
      raise ArgumentError.new("public key must be 32 bytes") unless @public_key.size == ED25519_PUBKEY_SIZE
    end

    def verify(message : Bytes, signature : Bytes) : Bool
      return false unless signature.size == ED25519_SIG_SIZE

      pkey = LibCrypto.evp_pkey_new_raw_public_key_cre(NID_ED25519, Pointer(Void).null, @public_key.to_unsafe, ED25519_PUBKEY_SIZE.to_u64)
      return false if pkey.null?
      ctx = LibCrypto.evp_md_ctx_new
      if ctx.null?
        LibCrypto.evp_pkey_free_cre(pkey)
        return false
      end
      begin
        rc = LibCrypto.evp_digestverifyinit_cre(ctx, Pointer(Void).null, Pointer(Void).null.as(LibCrypto::EVP_MD), Pointer(Void).null, pkey)
        return false unless rc == 1

        rc = LibCrypto.evp_digestverify_cre(ctx, signature.to_unsafe, signature.size.to_u64, message.to_unsafe, message.size.to_u64)
        rc == 1
      ensure
        LibCrypto.evp_md_ctx_free(ctx)
        LibCrypto.evp_pkey_free_cre(pkey)
      end
    end
  end
end
