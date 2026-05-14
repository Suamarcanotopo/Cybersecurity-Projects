# ===================
# ©AngelaMos | 2026
# env_file_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/rotators/env_file"

private def credential_for(path : String, key : String, bytes : Int32 = 32)
  CRE::Domain::Credential.new(
    id: UUID.random,
    external_id: "#{path}::#{key}",
    kind: CRE::Domain::CredentialKind::EnvFile,
    name: key,
    tags: {"path" => path, "key" => key, "bytes" => bytes.to_s} of String => String,
  )
end

describe CRE::Rotators::EnvFileRotator do
  it "executes the full 4-step contract" do
    tmp = File.tempfile("cre_env_test_") do |f|
      f << "API_KEY=oldvalue\nOTHER=keep\n"
    end
    path = tmp.path
    cred = credential_for(path, "API_KEY")
    rotator = CRE::Rotators::EnvFileRotator.new

    rotator.can_rotate?(cred).should be_true

    new_secret = rotator.generate(cred)
    new_secret.metadata["key"].should eq "API_KEY"
    new_secret.ciphertext.size.should be > 0

    rotator.apply(cred, new_secret)
    File.exists?("#{path}.pending.#{Process.pid}").should be_true
    rotator.verify(cred, new_secret).should be_true

    rotator.commit(cred, new_secret)
    File.exists?("#{path}.pending.#{Process.pid}").should be_false

    final = File.read(path)
    new_value = String.new(new_secret.ciphertext)
    final.includes?("API_KEY=#{new_value}").should be_true
    final.includes?("OTHER=keep").should be_true
    final.includes?("API_KEY=oldvalue").should be_false
  ensure
    tmp.try(&.delete)
  end

  it "rollback_apply removes the pending file" do
    tmp = File.tempfile("cre_env_rb_") do |f|
      f << "K=v\n"
    end
    cred = credential_for(tmp.path, "K")
    rotator = CRE::Rotators::EnvFileRotator.new

    s = rotator.generate(cred)
    rotator.apply(cred, s)
    File.exists?("#{tmp.path}.pending.#{Process.pid}").should be_true

    rotator.rollback_apply(cred, s)
    File.exists?("#{tmp.path}.pending.#{Process.pid}").should be_false
    File.read(tmp.path).should eq "K=v\n"
  ensure
    tmp.try(&.delete)
  end

  it "can_rotate? returns false without required tags" do
    bad_cred = CRE::Domain::Credential.new(
      id: UUID.random, external_id: "x",
      kind: CRE::Domain::CredentialKind::EnvFile,
      name: "x", tags: {} of String => String,
    )
    CRE::Rotators::EnvFileRotator.new.can_rotate?(bad_cred).should be_false
  end

  it "creates the file if missing" do
    path = File.tempname("cre_env_new_", ".env")
    cred = credential_for(path, "FRESH")
    rotator = CRE::Rotators::EnvFileRotator.new

    s = rotator.generate(cred)
    rotator.apply(cred, s)
    rotator.verify(cred, s).should be_true
    rotator.commit(cred, s)
    File.exists?(path).should be_true
    File.read(path).includes?("FRESH=").should be_true
  ensure
    File.delete(path) if path && File.exists?(path)
  end
end
