# ===================
# ©AngelaMos | 2026
# credential_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/domain/credential"

describe CRE::Domain::Credential do
  it "constructs with required fields" do
    c = CRE::Domain::Credential.new(
      id: UUID.random,
      external_id: "arn:aws:secretsmanager:us-east-1:1:secret:db-prod",
      kind: CRE::Domain::CredentialKind::AwsSecretsmgr,
      name: "db-prod",
      tags: {"env" => "prod"} of String => String,
    )
    c.kind.aws_secretsmgr?.should be_true
    c.tag(:env).should eq "prod"
  end

  it "returns nil for missing tag" do
    c = CRE::Domain::Credential.new(
      id: UUID.random,
      external_id: "x",
      kind: CRE::Domain::CredentialKind::EnvFile,
      name: "n",
      tags: {} of String => String,
    )
    c.tag(:env).should be_nil
  end

  it "supports kind predicates" do
    c = CRE::Domain::Credential.new(
      id: UUID.random,
      external_id: "x",
      kind: CRE::Domain::CredentialKind::GithubPat,
      name: "n",
      tags: {} of String => String,
    )
    c.kind.github_pat?.should be_true
    c.kind.env_file?.should be_false
  end

  it "tag() accepts both string and symbol keys" do
    c = CRE::Domain::Credential.new(
      id: UUID.random, external_id: "x",
      kind: CRE::Domain::CredentialKind::EnvFile,
      name: "n", tags: {"foo" => "bar"} of String => String,
    )
    c.tag("foo").should eq "bar"
    c.tag(:foo).should eq "bar"
  end

  it "rotation_anchor falls back to created_at when never rotated" do
    created = Time.utc - 3.days
    c = CRE::Domain::Credential.new(
      id: UUID.random,
      external_id: "x",
      kind: CRE::Domain::CredentialKind::EnvFile,
      name: "n",
      tags: {} of String => String,
      created_at: created,
    )
    c.rotation_anchor.should eq created
  end

  it "rotation_anchor uses last_rotated_at once set" do
    rotated = Time.utc - 1.hour
    c = CRE::Domain::Credential.new(
      id: UUID.random,
      external_id: "x",
      kind: CRE::Domain::CredentialKind::EnvFile,
      name: "n",
      tags: {} of String => String,
      created_at: Time.utc - 30.days,
      last_rotated_at: rotated,
    )
    c.rotation_anchor.should eq rotated
  end
end
