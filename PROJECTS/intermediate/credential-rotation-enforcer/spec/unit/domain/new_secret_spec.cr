# ===================
# ©AngelaMos | 2026
# new_secret_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/domain/new_secret"

describe CRE::Domain::NewSecret do
  it "wraps ciphertext + metadata + timestamp" do
    s = CRE::Domain::NewSecret.new(
      ciphertext: "abc".to_slice,
      metadata: {"version_id" => "v123"},
    )
    s.ciphertext.should eq "abc".to_slice
    s.metadata["version_id"].should eq "v123"
    s.generated_at.should be_close(Time.utc, 5.seconds)
  end

  it "defaults metadata to empty hash" do
    s = CRE::Domain::NewSecret.new(ciphertext: Bytes.new(8))
    s.metadata.should be_empty
  end

  it "ciphertext is exposed as Bytes" do
    s = CRE::Domain::NewSecret.new(ciphertext: Bytes[1, 2, 3])
    s.ciphertext.size.should eq 3
  end
end
