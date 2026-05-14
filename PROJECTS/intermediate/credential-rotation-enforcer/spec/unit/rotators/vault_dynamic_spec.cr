# ===================
# ©AngelaMos | 2026
# vault_dynamic_spec.cr
# ===================

require "../../spec_helper"
require "webmock"
require "../../../src/cre/rotators/vault_dynamic"

WebMock.allow_net_connect = false

private def vault_credential(current_lease : String? = nil)
  tags = {"role_path" => "database/creds/myrole"} of String => String
  tags["current_lease_id"] = current_lease if current_lease
  CRE::Domain::Credential.new(
    id: UUID.random,
    external_id: "database/creds/myrole",
    kind: CRE::Domain::CredentialKind::VaultDynamic,
    name: "myrole",
    tags: tags,
  )
end

private def vault_client
  CRE::Vault::Client.new(addr: "http://vault.test", token: "tok")
end

describe CRE::Rotators::VaultDynamicRotator do
  before_each { WebMock.reset }

  it "executes the full 4-step contract with lease revocation on commit" do
    cred = vault_credential(current_lease: "database/creds/myrole/old")

    WebMock.stub(:get, "http://vault.test/v1/database/creds/myrole")
      .to_return(body: %({"lease_id":"database/creds/myrole/new","lease_duration":3600,"data":{"username":"u","password":"p"}}))

    rotator = CRE::Rotators::VaultDynamicRotator.new(vault_client)
    rotator.can_rotate?(cred).should be_true

    new_secret = rotator.generate(cred)
    new_secret.metadata["lease_id"].should eq "database/creds/myrole/new"
    new_secret.metadata["old_lease_id"].should eq "database/creds/myrole/old"

    rotator.apply(cred, new_secret) # no-op

    WebMock.stub(:put, "http://vault.test/v1/sys/leases/renew")
      .to_return(body: %({"lease_id":"database/creds/myrole/new","lease_duration":3600}))
    rotator.verify(cred, new_secret).should be_true

    revoked = false
    WebMock.stub(:put, "http://vault.test/v1/sys/leases/revoke")
      .with(body: %({"lease_id":"database/creds/myrole/old"}))
      .to_return { |_| revoked = true; HTTP::Client::Response.new(200, body: "{}") }
    rotator.commit(cred, new_secret)
    revoked.should be_true
  end

  it "verify returns false on Vault error" do
    cred = vault_credential
    WebMock.stub(:put, "http://vault.test/v1/sys/leases/renew")
      .to_return(status: 403, body: %({"errors":["denied"]}))
    rotator = CRE::Rotators::VaultDynamicRotator.new(vault_client)
    s = CRE::Domain::NewSecret.new(
      ciphertext: "{}".to_slice,
      metadata: {"lease_id" => "x"},
    )
    rotator.verify(cred, s).should be_false
  end

  it "rollback_apply revokes the new lease" do
    cred = vault_credential
    rotator = CRE::Rotators::VaultDynamicRotator.new(vault_client)
    s = CRE::Domain::NewSecret.new(
      ciphertext: "{}".to_slice,
      metadata: {"lease_id" => "new-lease-id"},
    )
    revoked = false
    WebMock.stub(:put, "http://vault.test/v1/sys/leases/revoke")
      .with(body: %({"lease_id":"new-lease-id"}))
      .to_return { |_| revoked = true; HTTP::Client::Response.new(200, body: "{}") }
    rotator.rollback_apply(cred, s)
    revoked.should be_true
  end

  it "skips lease revocation when no current_lease_id" do
    cred = vault_credential # no current_lease_id
    WebMock.stub(:get, "http://vault.test/v1/database/creds/myrole")
      .to_return(body: %({"lease_id":"new","lease_duration":3600,"data":{"username":"u","password":"p"}}))
    rotator = CRE::Rotators::VaultDynamicRotator.new(vault_client)
    s = rotator.generate(cred)
    # commit should be a no-op (no old lease to revoke)
    rotator.commit(cred, s)
    # If a stub was missing webmock would have raised; absence proves no PUT happened.
  end
end
