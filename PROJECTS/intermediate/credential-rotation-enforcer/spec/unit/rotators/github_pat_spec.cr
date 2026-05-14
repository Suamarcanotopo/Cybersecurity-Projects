# ===================
# ©AngelaMos | 2026
# github_pat_spec.cr
# ===================

require "../../spec_helper"
require "webmock"
require "../../../src/cre/rotators/github_pat"

WebMock.allow_net_connect = false

private def github_credential(old_pat_id : String = "111")
  CRE::Domain::Credential.new(
    id: UUID.random,
    external_id: "deploy-bot",
    kind: CRE::Domain::CredentialKind::GithubPat,
    name: "deploy-bot",
    tags: {
      "name"            => "deploy-bot",
      "scopes"          => %(["repo","read:org"]),
      "old_pat_id"      => old_pat_id,
      "expires_in_days" => "90",
    } of String => String,
  )
end

private def gh_client
  CRE::Github::Client.new(token: "ghp_admin")
end

describe CRE::Rotators::GithubPatRotator do
  before_each { WebMock.reset }

  it "executes the full 4-step contract" do
    cred = github_credential

    WebMock.stub(:post, "https://api.github.com/user/personal-access-tokens")
      .to_return(body: %({"id":99999,"token":"ghp_new","expires_at":"2026-07-01T00:00:00Z"}))

    rotator = CRE::Rotators::GithubPatRotator.new(gh_client)
    rotator.can_rotate?(cred).should be_true

    new_secret = rotator.generate(cred)
    new_secret.metadata["new_pat_id"].should eq "99999"
    new_secret.metadata["old_pat_id"].should eq "111"
    String.new(new_secret.ciphertext).should eq "ghp_new"

    rotator.apply(cred, new_secret) # no-op

    WebMock.stub(:get, "https://api.github.com/user")
      .with(headers: {"Authorization" => "Bearer ghp_new"})
      .to_return(body: %({"login":"deploy-bot"}))
    rotator.verify(cred, new_secret).should be_true

    deleted_old = false
    WebMock.stub(:delete, "https://api.github.com/user/personal-access-tokens/111")
      .to_return { |_| deleted_old = true; HTTP::Client::Response.new(200, body: "{}") }
    rotator.commit(cred, new_secret)
    deleted_old.should be_true
  end

  it "verify returns false when /user fails with new token" do
    cred = github_credential
    WebMock.stub(:get, "https://api.github.com/user")
      .to_return(status: 401, body: %({"message":"bad"}))
    rotator = CRE::Rotators::GithubPatRotator.new(gh_client)
    s = CRE::Domain::NewSecret.new(
      ciphertext: "ghp_bad".to_slice,
      metadata: {"new_pat_id" => "1", "old_pat_id" => "0"},
    )
    rotator.verify(cred, s).should be_false
  end

  it "rollback_apply deletes the new PAT" do
    cred = github_credential
    rotator = CRE::Rotators::GithubPatRotator.new(gh_client)
    s = CRE::Domain::NewSecret.new(
      ciphertext: "ghp_new".to_slice,
      metadata: {"new_pat_id" => "888"},
    )
    deleted = false
    WebMock.stub(:delete, "https://api.github.com/user/personal-access-tokens/888")
      .to_return { |_| deleted = true; HTTP::Client::Response.new(200, body: "{}") }
    rotator.rollback_apply(cred, s)
    deleted.should be_true
  end
end
