# ===================
# ©AngelaMos | 2026
# random_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/crypto/random"

describe CRE::Crypto::Random do
  it "generates 32 secure bytes" do
    bytes = CRE::Crypto::Random.bytes(32)
    bytes.size.should eq 32
  end

  it "two calls produce different bytes (overwhelmingly likely)" do
    a = CRE::Crypto::Random.bytes(32)
    b = CRE::Crypto::Random.bytes(32)
    a.should_not eq b
  end

  it "hex returns 2n hex chars" do
    h = CRE::Crypto::Random.hex(16)
    h.size.should eq 32
    h.each_char { |c| ("0123456789abcdef".includes?(c)).should be_true }
  end

  describe "constant_time_equal?" do
    it "returns true for equal slices" do
      a = Bytes[1, 2, 3, 4]
      b = Bytes[1, 2, 3, 4]
      CRE::Crypto::Random.constant_time_equal?(a, b).should be_true
    end

    it "returns false for different slices" do
      a = Bytes[1, 2, 3, 4]
      b = Bytes[1, 2, 3, 5]
      CRE::Crypto::Random.constant_time_equal?(a, b).should be_false
    end

    it "returns false for different sizes" do
      a = Bytes[1, 2, 3]
      b = Bytes[1, 2, 3, 4]
      CRE::Crypto::Random.constant_time_equal?(a, b).should be_false
    end
  end
end
