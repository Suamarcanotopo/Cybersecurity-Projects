# ===================
# ©AngelaMos | 2026
# envelope.cr
# ===================

require "./aead"
require "./kek"
require "./random"

module CRE::Crypto
  ALGORITHM_AES_256_GCM = 1_i16

  struct SealedSecret
    getter ciphertext : Bytes
    getter dek_wrapped : Bytes
    getter kek_version : Int32
    getter algorithm_id : Int16

    def initialize(@ciphertext, @dek_wrapped, @kek_version, @algorithm_id)
    end
  end

  class Envelope
    def initialize(@kek : Kek::Kek)
    end

    def seal(plaintext : Bytes, aad : Bytes) : SealedSecret
      dek = Random.bytes(32)
      ct, nonce, tag = Aead.encrypt(plaintext, dek, aad)
      packed_ct = pack(nonce, tag, ct)

      wrap_aad = "kek-wrap|v#{@kek.version}".to_slice
      wrapped_ct, wrap_nonce, wrap_tag = Aead.encrypt(dek, @kek.bytes, wrap_aad)
      packed_wrap = pack(wrap_nonce, wrap_tag, wrapped_ct)

      SealedSecret.new(
        ciphertext: packed_ct,
        dek_wrapped: packed_wrap,
        kek_version: @kek.version,
        algorithm_id: ALGORITHM_AES_256_GCM,
      )
    end

    def open(sealed : SealedSecret, aad : Bytes) : Bytes
      raise "unsupported algorithm_id #{sealed.algorithm_id}" unless sealed.algorithm_id == ALGORITHM_AES_256_GCM
      raise "kek version mismatch (sealed=#{sealed.kek_version}, kek=#{@kek.version})" unless sealed.kek_version == @kek.version

      wrap_nonce, wrap_tag, wrapped = unpack(sealed.dek_wrapped)
      wrap_aad = "kek-wrap|v#{@kek.version}".to_slice
      dek = Aead.decrypt(wrapped, @kek.bytes, wrap_aad, wrap_nonce, wrap_tag)

      nonce, tag, ct = unpack(sealed.ciphertext)
      Aead.decrypt(ct, dek, aad, nonce, tag)
    end

    private def pack(nonce : Bytes, tag : Bytes, body : Bytes) : Bytes
      io = IO::Memory.new(nonce.size + tag.size + body.size)
      io.write(nonce); io.write(tag); io.write(body)
      io.to_slice
    end

    private def unpack(packed : Bytes) : {Bytes, Bytes, Bytes}
      n = Aead::NONCE_SIZE
      t = Aead::TAG_SIZE
      raise "packed too small" if packed.size < n + t
      nonce = packed[0, n]
      tag = packed[n, t]
      body = packed[n + t, packed.size - n - t]
      {nonce, tag, body}
    end
  end
end
