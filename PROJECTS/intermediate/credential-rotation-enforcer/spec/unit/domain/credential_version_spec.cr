# ===================
# ©AngelaMos | 2026
# credential_version_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/domain/credential_version"

describe CRE::Domain::CredentialVersion do
  it "constructs with all fields" do
    v = CRE::Domain::CredentialVersion.new(
      id: UUID.random,
      credential_id: UUID.random,
      ciphertext: "x".to_slice,
      dek_wrapped: "y".to_slice,
      kek_version: 1,
      algorithm_id: 1_i16,
      metadata: {} of String => String,
    )
    v.kek_version.should eq 1
    v.algorithm_id.should eq 1_i16
    v.revoked_at.should be_nil
  end

  it "reports revocation" do
    revoked_at = Time.utc - 1.hour
    v = CRE::Domain::CredentialVersion.new(
      id: UUID.random,
      credential_id: UUID.random,
      ciphertext: Bytes.new(0),
      dek_wrapped: Bytes.new(0),
      kek_version: 1,
      algorithm_id: 1_i16,
      revoked_at: revoked_at,
    )
    v.revoked?.should be_true
    v.revoked_at.should eq revoked_at
  end

  it "is not revoked by default" do
    v = CRE::Domain::CredentialVersion.new(
      id: UUID.random,
      credential_id: UUID.random,
      ciphertext: Bytes.new(0),
      dek_wrapped: Bytes.new(0),
      kek_version: 1,
      algorithm_id: 1_i16,
    )
    v.revoked?.should be_false
  end
end
