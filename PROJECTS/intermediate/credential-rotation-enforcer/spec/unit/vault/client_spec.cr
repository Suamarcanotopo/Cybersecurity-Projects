# ===================
# ©AngelaMos | 2026
# client_spec.cr
# ===================

require "../../spec_helper"
require "webmock"
require "../../../src/cre/vault/client"

WebMock.allow_net_connect = false

private def fresh_client
  CRE::Vault::Client.new(addr: "http://vault.test", token: "test-token")
end

describe CRE::Vault::Client do
  before_each { WebMock.reset }

  it "reads a dynamic secret" do
    WebMock.stub(:get, "http://vault.test/v1/database/creds/myrole")
      .with(headers: {"X-Vault-Token" => "test-token"})
      .to_return(body: %({
        "lease_id":"database/creds/myrole/abc",
        "lease_duration":3600,
        "data":{"username":"v-token-myrole-xyz","password":"hunter2"}
      }))

    secret = fresh_client.read_dynamic("database/creds/myrole")
    secret.lease_id.should eq "database/creds/myrole/abc"
    secret.lease_duration.should eq 3600
    secret.username.should eq "v-token-myrole-xyz"
    secret.password.should eq "hunter2"
  end

  it "revokes a lease" do
    called = false
    WebMock.stub(:put, "http://vault.test/v1/sys/leases/revoke")
      .with(body: %({"lease_id":"database/creds/myrole/abc"}))
      .to_return { |_| called = true; HTTP::Client::Response.new(200, body: "{}") }
    fresh_client.revoke_lease("database/creds/myrole/abc")
    called.should be_true
  end

  it "renews a lease" do
    WebMock.stub(:put, "http://vault.test/v1/sys/leases/renew")
      .to_return(body: %({"lease_id":"x","lease_duration":7200}))
    fresh_client.renew_lease("x").should eq 7200
  end

  it "raises VaultError on non-2xx" do
    WebMock.stub(:get, "http://vault.test/v1/database/creds/missing")
      .to_return(status: 404, body: %({"errors":["role missing"]}))
    expect_raises(CRE::Vault::VaultError) do
      fresh_client.read_dynamic("database/creds/missing")
    end
  end
end
