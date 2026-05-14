# ===================
# ©AngelaMos | 2026
# merkle_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/audit/merkle"

describe CRE::Audit::Merkle do
  it "single leaf root equals the leaf" do
    leaf = "x".to_slice
    CRE::Audit::Merkle.root([leaf]).should eq leaf
  end

  it "balanced tree root is deterministic" do
    leaves = ["a", "b", "c", "d"].map(&.to_slice)
    r1 = CRE::Audit::Merkle.root(leaves)
    r2 = CRE::Audit::Merkle.root(leaves)
    r1.should eq r2
    r1.size.should eq 32
  end

  it "different leaves produce different roots" do
    a = CRE::Audit::Merkle.root(["a", "b"].map(&.to_slice))
    b = CRE::Audit::Merkle.root(["a", "c"].map(&.to_slice))
    a.should_not eq b
  end

  it "odd leaf count is supported (last is promoted)" do
    leaves = ["a", "b", "c"].map(&.to_slice)
    r = CRE::Audit::Merkle.root(leaves)
    r.size.should eq 32
  end

  it "raises on empty input" do
    expect_raises(ArgumentError) { CRE::Audit::Merkle.root([] of Bytes) }
  end
end
