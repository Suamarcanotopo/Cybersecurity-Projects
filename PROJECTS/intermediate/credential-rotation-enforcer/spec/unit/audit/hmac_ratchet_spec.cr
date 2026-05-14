# ===================
# ©AngelaMos | 2026
# hmac_ratchet_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/audit/hmac_ratchet"

describe CRE::Audit::HmacRatchet do
  it "produces 32-byte HMAC" do
    r = CRE::Audit::HmacRatchet.new(Bytes.new(32, 0_u8), version: 1, ratchet_every: 1024)
    h = r.sign("payload".to_slice)
    h.size.should eq 32
    r.version.should eq 1
  end

  it "rotates after N entries" do
    r = CRE::Audit::HmacRatchet.new(Bytes.new(32, 0_u8), version: 1, ratchet_every: 3)
    3.times { r.sign("x".to_slice) }
    r.version.should eq 1 # not yet rotated
    r.sign("x".to_slice)
    r.version.should eq 2 # rotated on the 4th call
  end

  it "different keys produce different HMACs" do
    a = CRE::Audit::HmacRatchet.new(Bytes.new(32, 0_u8), 1, 1024).sign("x".to_slice)
    b = CRE::Audit::HmacRatchet.new(Bytes.new(32, 1_u8), 1, 1024).sign("x".to_slice)
    a.should_not eq b
  end

  it "rejects keys of incorrect size" do
    expect_raises(ArgumentError) do
      CRE::Audit::HmacRatchet.new(Bytes.new(16), 1, 1024)
    end
  end

  it "verify (static) round-trips" do
    key = Bytes.new(32, 0xff_u8)
    payload = "p".to_slice
    h = OpenSSL::HMAC.digest(:sha256, key, payload)
    CRE::Audit::HmacRatchet.verify(payload, h, key).should be_true
  end
end
