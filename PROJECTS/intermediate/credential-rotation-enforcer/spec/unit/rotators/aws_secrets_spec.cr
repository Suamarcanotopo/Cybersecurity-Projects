# ===================
# ©AngelaMos | 2026
# aws_secrets_spec.cr
# ===================

require "../../spec_helper"
require "webmock"
require "../../../src/cre/rotators/aws_secrets"

WebMock.allow_net_connect = false

private def aws_credential
  CRE::Domain::Credential.new(
    id: UUID.random,
    external_id: "arn:aws:secretsmanager:us-east-1:123456789012:secret:my-db-prod",
    kind: CRE::Domain::CredentialKind::AwsSecretsmgr,
    name: "my-db-prod",
    tags: {
      "secret_arn"   => "arn:aws:secretsmanager:us-east-1:123456789012:secret:my-db-prod",
      "value_length" => "16",
    } of String => String,
  )
end

private def fresh_client : CRE::Aws::SecretsManagerClient
  CRE::Aws::SecretsManagerClient.new(
    access_key_id: "AKID",
    secret_access_key: "secret",
    region: "us-east-1",
  )
end

describe CRE::Rotators::AwsSecretsRotator do
  before_each { WebMock.reset }

  it "executes the full 4-step contract" do
    cred = aws_credential

    WebMock.stub(:post, "https://secretsmanager.us-east-1.amazonaws.com/")
      .with(headers: {"X-Amz-Target" => "secretsmanager.PutSecretValue"})
      .to_return(body: %({"VersionId":"new-v"}))

    rotator = CRE::Rotators::AwsSecretsRotator.new(fresh_client)
    rotator.can_rotate?(cred).should be_true

    new_secret = rotator.generate(cred)
    new_secret.metadata["version_id"].should eq "new-v"
    new_secret.metadata["secret_arn"].should eq cred.tag("secret_arn")

    rotator.apply(cred, new_secret) # no-op

    expected_value = String.new(new_secret.ciphertext)
    WebMock.stub(:post, "https://secretsmanager.us-east-1.amazonaws.com/")
      .with(headers: {"X-Amz-Target" => "secretsmanager.GetSecretValue"})
      .to_return(body: %({"VersionId":"new-v","SecretString":#{expected_value.to_json}}))

    rotator.verify(cred, new_secret).should be_true

    # Commit: GetSecretValue (current) + UpdateSecretVersionStage (move) + UpdateSecretVersionStage (remove pending)
    WebMock.stub(:post, "https://secretsmanager.us-east-1.amazonaws.com/")
      .with(headers: {"X-Amz-Target" => "secretsmanager.GetSecretValue"})
      .to_return(body: %({"VersionId":"old-v","SecretString":"oldval"}))
    WebMock.stub(:post, "https://secretsmanager.us-east-1.amazonaws.com/")
      .with(headers: {"X-Amz-Target" => "secretsmanager.UpdateSecretVersionStage"})
      .to_return(body: "{}")

    rotator.commit(cred, new_secret)
  end

  it "verify returns false on retrieved-value mismatch" do
    cred = aws_credential
    WebMock.stub(:post, "https://secretsmanager.us-east-1.amazonaws.com/")
      .with(headers: {"X-Amz-Target" => "secretsmanager.GetSecretValue"})
      .to_return(body: %({"VersionId":"v","SecretString":"different"}))

    rotator = CRE::Rotators::AwsSecretsRotator.new(fresh_client)
    s = CRE::Domain::NewSecret.new(
      ciphertext: "expected".to_slice,
      metadata: {"version_id" => "v", "secret_arn" => cred.tag("secret_arn").not_nil!},
    )
    rotator.verify(cred, s).should be_false
  end

  it "rollback_apply removes AWSPENDING stage" do
    cred = aws_credential
    rotator = CRE::Rotators::AwsSecretsRotator.new(fresh_client)
    s = CRE::Domain::NewSecret.new(
      ciphertext: "x".to_slice,
      metadata: {"version_id" => "v", "secret_arn" => cred.tag("secret_arn").not_nil!},
    )

    called = false
    WebMock.stub(:post, "https://secretsmanager.us-east-1.amazonaws.com/")
      .with(headers: {"X-Amz-Target" => "secretsmanager.UpdateSecretVersionStage"})
      .to_return { |_req| called = true; HTTP::Client::Response.new(200, body: "{}") }

    rotator.rollback_apply(cred, s)
    called.should be_true
  end

  it "can_rotate? returns false without secret_arn tag" do
    bad = CRE::Domain::Credential.new(
      id: UUID.random, external_id: "x",
      kind: CRE::Domain::CredentialKind::AwsSecretsmgr,
      name: "x", tags: {} of String => String,
    )
    CRE::Rotators::AwsSecretsRotator.new(fresh_client).can_rotate?(bad).should be_false
  end
end
