# ===================
# ©AngelaMos | 2026
# client_spec.cr
# ===================

require "../../spec_helper"
require "webmock"
require "../../../src/cre/github/client"

WebMock.allow_net_connect = false

private def fresh_client
  CRE::Github::Client.new(token: "ghp_admin")
end

describe CRE::Github::Client do
  before_each { WebMock.reset }

  it "creates a fine-grained PAT" do
    WebMock.stub(:post, "https://api.github.com/user/personal-access-tokens")
      .with(headers: {"Authorization" => "Bearer ghp_admin"})
      .to_return(body: %({"id":12345,"token":"ghp_newvalue","expires_at":"2026-07-01T00:00:00Z"}))

    token = fresh_client.create_pat("my-pat", ["repo", "read:org"], 90)
    token.id.should eq 12345_i64
    token.token_value.should eq "ghp_newvalue"
    token.expires_at.should eq "2026-07-01T00:00:00Z"
  end

  it "deletes a PAT" do
    deleted = false
    WebMock.stub(:delete, "https://api.github.com/user/personal-access-tokens/12345")
      .with(headers: {"Authorization" => "Bearer ghp_admin"})
      .to_return { |_| deleted = true; HTTP::Client::Response.new(200, body: "{}") }
    fresh_client.delete_pat(12345_i64)
    deleted.should be_true
  end

  it "fetches the authenticated user" do
    WebMock.stub(:get, "https://api.github.com/user")
      .to_return(body: %({"login":"octocat","id":1}))
    user = fresh_client.me
    user["login"].as_s.should eq "octocat"
  end

  it "raises GithubError on non-2xx" do
    WebMock.stub(:get, "https://api.github.com/user")
      .to_return(status: 401, body: %({"message":"Bad credentials"}))
    expect_raises(CRE::Github::GithubError) { fresh_client.me }
  end
end
