# ===================
# ©AngelaMos | 2026
# aead_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/crypto/aead"
require "../../../src/cre/crypto/random"

describe CRE::Crypto::Aead do
  it "round-trips AES-256-GCM with AAD" do
    key = CRE::Crypto::Random.bytes(32)
    plaintext = "secret value 123".to_slice
    aad = "tenant=t1|cred=c1|ver=v1".to_slice

    ct, nonce, tag = CRE::Crypto::Aead.encrypt(plaintext, key, aad)
    decrypted = CRE::Crypto::Aead.decrypt(ct, key, aad, nonce, tag)
    decrypted.should eq plaintext
  end

  it "fails to decrypt with wrong AAD" do
    key = CRE::Crypto::Random.bytes(32)
    plaintext = "secret".to_slice
    aad = "right".to_slice

    ct, nonce, tag = CRE::Crypto::Aead.encrypt(plaintext, key, aad)
    expect_raises(CRE::Crypto::Aead::Error) do
      CRE::Crypto::Aead.decrypt(ct, key, "wrong".to_slice, nonce, tag)
    end
  end

  it "fails to decrypt with tampered ciphertext" do
    key = CRE::Crypto::Random.bytes(32)
    plaintext = "abc-def".to_slice
    aad = "x".to_slice

    ct, nonce, tag = CRE::Crypto::Aead.encrypt(plaintext, key, aad)
    ct[0] ^= 0x01_u8
    expect_raises(CRE::Crypto::Aead::Error) do
      CRE::Crypto::Aead.decrypt(ct, key, aad, nonce, tag)
    end
  end

  it "rejects keys of incorrect size" do
    bad_key = Bytes.new(16)
    expect_raises(ArgumentError) do
      CRE::Crypto::Aead.encrypt("x".to_slice, bad_key, "a".to_slice)
    end
  end
end
