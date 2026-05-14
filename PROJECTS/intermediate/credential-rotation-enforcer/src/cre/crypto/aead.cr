# ===================
# ©AngelaMos | 2026
# aead.cr
# ===================

require "openssl"
require "openssl/lib_crypto"

lib LibCrypto
  fun evp_cipher_ctx_ctrl_cre = EVP_CIPHER_CTX_ctrl(ctx : EVP_CIPHER_CTX, type : LibC::Int, arg : LibC::Int, ptr : Void*) : LibC::Int
  fun evp_aes_256_gcm_cre = EVP_aes_256_gcm : EVP_CIPHER
end

module CRE::Crypto
  module Aead
    NONCE_SIZE = 12
    TAG_SIZE   = 16

    EVP_CTRL_GCM_SET_IVLEN =  0x9
    EVP_CTRL_GCM_GET_TAG   = 0x10
    EVP_CTRL_GCM_SET_TAG   = 0x11

    class Error < OpenSSL::Error; end

    def self.encrypt(plaintext : Bytes, key : Bytes, aad : Bytes) : {Bytes, Bytes, Bytes}
      raise ArgumentError.new("key must be 32 bytes (AES-256)") unless key.size == 32
      ctx = LibCrypto.evp_cipher_ctx_new
      raise Error.new("EVP_CIPHER_CTX_new") if ctx.null?
      begin
        nonce = ::Random::Secure.random_bytes(NONCE_SIZE)
        cipher = LibCrypto.evp_aes_256_gcm_cre

        check(LibCrypto.evp_cipherinit_ex(ctx, cipher, Pointer(Void).null, Pointer(UInt8).null, Pointer(UInt8).null, 1), "EncryptInit (cipher)")
        check(LibCrypto.evp_cipher_ctx_ctrl_cre(ctx, EVP_CTRL_GCM_SET_IVLEN, NONCE_SIZE, Pointer(Void).null), "set IV len")
        check(LibCrypto.evp_cipherinit_ex(ctx, Pointer(Void).null.as(LibCrypto::EVP_CIPHER), Pointer(Void).null, key.to_unsafe, nonce.to_unsafe, 1), "EncryptInit (key/iv)")

        unless aad.empty?
          aad_outl = 0
          check(LibCrypto.evp_cipherupdate(ctx, Pointer(UInt8).null, pointerof(aad_outl), aad.to_unsafe, aad.size), "EncryptUpdate (AAD)")
        end

        ct_buf = Bytes.new(plaintext.size + 16)
        outl = 0
        check(LibCrypto.evp_cipherupdate(ctx, ct_buf.to_unsafe, pointerof(outl), plaintext.to_unsafe, plaintext.size), "EncryptUpdate (data)")
        ct_size = outl

        final_outl = 0
        check(LibCrypto.evp_cipherfinal_ex(ctx, ct_buf.to_unsafe + ct_size, pointerof(final_outl)), "EncryptFinal_ex")
        ct_size += final_outl

        tag = Bytes.new(TAG_SIZE)
        check(LibCrypto.evp_cipher_ctx_ctrl_cre(ctx, EVP_CTRL_GCM_GET_TAG, TAG_SIZE, tag.to_unsafe.as(Void*)), "get tag")

        {ct_buf[0, ct_size], nonce, tag}
      ensure
        LibCrypto.evp_cipher_ctx_free(ctx)
      end
    end

    def self.decrypt(ciphertext : Bytes, key : Bytes, aad : Bytes, nonce : Bytes, tag : Bytes) : Bytes
      raise ArgumentError.new("key must be 32 bytes") unless key.size == 32
      ctx = LibCrypto.evp_cipher_ctx_new
      raise Error.new("EVP_CIPHER_CTX_new") if ctx.null?
      begin
        cipher = LibCrypto.evp_aes_256_gcm_cre

        check(LibCrypto.evp_cipherinit_ex(ctx, cipher, Pointer(Void).null, Pointer(UInt8).null, Pointer(UInt8).null, 0), "DecryptInit (cipher)")
        check(LibCrypto.evp_cipher_ctx_ctrl_cre(ctx, EVP_CTRL_GCM_SET_IVLEN, NONCE_SIZE, Pointer(Void).null), "set IV len")
        check(LibCrypto.evp_cipherinit_ex(ctx, Pointer(Void).null.as(LibCrypto::EVP_CIPHER), Pointer(Void).null, key.to_unsafe, nonce.to_unsafe, 0), "DecryptInit (key/iv)")

        unless aad.empty?
          aad_outl = 0
          check(LibCrypto.evp_cipherupdate(ctx, Pointer(UInt8).null, pointerof(aad_outl), aad.to_unsafe, aad.size), "DecryptUpdate (AAD)")
        end

        pt_buf = Bytes.new(ciphertext.size + 16)
        outl = 0
        check(LibCrypto.evp_cipherupdate(ctx, pt_buf.to_unsafe, pointerof(outl), ciphertext.to_unsafe, ciphertext.size), "DecryptUpdate (data)")
        pt_size = outl

        check(LibCrypto.evp_cipher_ctx_ctrl_cre(ctx, EVP_CTRL_GCM_SET_TAG, TAG_SIZE, tag.to_unsafe.as(Void*)), "set tag")

        final_outl = 0
        result = LibCrypto.evp_cipherfinal_ex(ctx, pt_buf.to_unsafe + pt_size, pointerof(final_outl))
        if result <= 0
          raise Error.new("AEAD authentication failed (tag mismatch / tampered ciphertext)")
        end
        pt_size += final_outl

        pt_buf[0, pt_size]
      ensure
        LibCrypto.evp_cipher_ctx_free(ctx)
      end
    end

    private def self.check(rc : LibC::Int, what : String) : Nil
      raise Error.new("#{what} failed (rc=#{rc})") unless rc == 1
    end
  end
end
