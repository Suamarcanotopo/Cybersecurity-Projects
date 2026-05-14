# ===================
# ©AngelaMos | 2026
# aead_property_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/crypto/aead"
require "../../../src/cre/crypto/random"

describe CRE::Crypto::Aead do
  it "encrypt -> decrypt is identity for 100 random plaintexts of varying sizes" do
    rng = ::Random.new(42)
    100.times do
      size = rng.rand(0..1024)
      plaintext = Bytes.new(size) { rng.rand(0_u8..255_u8) }
      key = CRE::Crypto::Random.bytes(32)
      aad = CRE::Crypto::Random.bytes(rng.rand(0..64))

      ct, nonce, tag = CRE::Crypto::Aead.encrypt(plaintext, key, aad)
      decrypted = CRE::Crypto::Aead.decrypt(ct, key, aad, nonce, tag)
      decrypted.should eq plaintext
    end
  end
end
