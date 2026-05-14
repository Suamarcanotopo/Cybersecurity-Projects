# ===================
# ©AngelaMos | 2026
# envelope_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/crypto/envelope"
require "../../../src/cre/crypto/kek"

describe CRE::Crypto::Envelope do
  it "encrypts and decrypts with envelope" do
    ENV["KEK_TEST_HEX"] = "0" * 64
    kek = CRE::Crypto::Kek::EnvKek.new("KEK_TEST_HEX", version: 1)
    env = CRE::Crypto::Envelope.new(kek)

    plaintext = "very secret".to_slice
    aad = "ctx".to_slice

    sealed = env.seal(plaintext, aad)
    sealed.algorithm_id.should eq CRE::Crypto::ALGORITHM_AES_256_GCM
    sealed.kek_version.should eq 1

    opened = env.open(sealed, aad)
    opened.should eq plaintext
  ensure
    ENV.delete("KEK_TEST_HEX")
  end

  it "fails to open with mismatched AAD" do
    ENV["KEK_TEST_HEX2"] = "0" * 64
    kek = CRE::Crypto::Kek::EnvKek.new("KEK_TEST_HEX2", version: 1)
    env = CRE::Crypto::Envelope.new(kek)

    sealed = env.seal("plaintext".to_slice, "good-aad".to_slice)
    expect_raises(CRE::Crypto::Aead::Error) do
      env.open(sealed, "bad-aad".to_slice)
    end
  ensure
    ENV.delete("KEK_TEST_HEX2")
  end

  it "produces different ciphertexts for the same plaintext (random DEK + nonce)" do
    ENV["KEK_TEST_HEX3"] = "0" * 64
    kek = CRE::Crypto::Kek::EnvKek.new("KEK_TEST_HEX3", version: 1)
    env = CRE::Crypto::Envelope.new(kek)

    aad = "x".to_slice
    a = env.seal("same".to_slice, aad)
    b = env.seal("same".to_slice, aad)
    a.ciphertext.should_not eq b.ciphertext
    a.dek_wrapped.should_not eq b.dek_wrapped
  ensure
    ENV.delete("KEK_TEST_HEX3")
  end
end
