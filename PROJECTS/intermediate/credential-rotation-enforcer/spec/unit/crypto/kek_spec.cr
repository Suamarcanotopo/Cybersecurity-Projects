# ===================
# ©AngelaMos | 2026
# kek_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/crypto/kek"

describe CRE::Crypto::Kek do
  it "loads a 32-byte KEK from env hex" do
    hex = "0" * 64
    ENV["TEST_KEK_HEX"] = hex
    kek = CRE::Crypto::Kek::EnvKek.new("TEST_KEK_HEX", version: 1)
    kek.bytes.size.should eq 32
    kek.version.should eq 1
    kek.source.should eq "env:TEST_KEK_HEX"
  ensure
    ENV.delete("TEST_KEK_HEX")
  end

  it "raises on wrong-length hex" do
    ENV["BAD_KEK"] = "abcd"
    expect_raises(CRE::Crypto::Kek::InvalidKekError) do
      CRE::Crypto::Kek::EnvKek.new("BAD_KEK", version: 1)
    end
  ensure
    ENV.delete("BAD_KEK")
  end

  it "raises on missing env var" do
    expect_raises(CRE::Crypto::Kek::InvalidKekError) do
      CRE::Crypto::Kek::EnvKek.new("DOES_NOT_EXIST_XYZ_KEK", version: 1)
    end
  end
end
