# ===================
# ©AngelaMos | 2026
# hash_chain_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/audit/hash_chain"

describe CRE::Audit::HashChain do
  it "first hash is 32 zero bytes" do
    g = CRE::Audit::HashChain.genesis
    g.size.should eq 32
    g.all? { |b| b == 0_u8 }.should be_true
  end

  it "next_hash is deterministic" do
    prev = CRE::Audit::HashChain.genesis
    payload = "hello".to_slice
    a = CRE::Audit::HashChain.next_hash(prev, payload)
    b = CRE::Audit::HashChain.next_hash(prev, payload)
    a.should eq b
    a.size.should eq 32
  end

  it "different prev produces different hash" do
    payload = "x".to_slice
    a = CRE::Audit::HashChain.next_hash(Bytes.new(32, 0_u8), payload)
    b = CRE::Audit::HashChain.next_hash(Bytes.new(32, 1_u8), payload)
    a.should_not eq b
  end

  it "different payload produces different hash" do
    prev = CRE::Audit::HashChain.genesis
    a = CRE::Audit::HashChain.next_hash(prev, "a".to_slice)
    b = CRE::Audit::HashChain.next_hash(prev, "b".to_slice)
    a.should_not eq b
  end

  it "verify_chain detects tampering" do
    pairs = [] of {Bytes, Bytes}
    h = CRE::Audit::HashChain.genesis
    payloads = ["a", "b", "c", "d"].map(&.to_slice)
    payloads.each do |p|
      next_h = CRE::Audit::HashChain.next_hash(h, p)
      pairs << {h, next_h}
      h = next_h
    end

    CRE::Audit::HashChain.verify(pairs, payloads).should be_true

    tampered = payloads.dup
    tampered[2] = "BAD".to_slice
    CRE::Audit::HashChain.verify(pairs, tampered).should be_false
  end

  it "verify_chain returns true for empty input" do
    CRE::Audit::HashChain.verify([] of {Bytes, Bytes}, [] of Bytes).should be_true
  end

  it "verify_chain returns false on mismatched array sizes" do
    CRE::Audit::HashChain.verify([] of {Bytes, Bytes}, ["x".to_slice]).should be_false
  end
end
