# ===================
# ©AngelaMos | 2026
# secrets_client_spec.cr
# ===================

require "../../spec_helper"
require "webmock"
require "../../../src/cre/aws/secrets_client"

WebMock.allow_net_connect = false

private def fresh_client : CRE::Aws::SecretsManagerClient
  CRE::Aws::SecretsManagerClient.new(
    access_key_id: "AKID",
    secret_access_key: "secret",
    region: "us-east-1",
  )
end

describe CRE::Aws::SecretsManagerClient do
  before_each { WebMock.reset }

  it "calls PutSecretValue and returns version_id" do
    WebMock.stub(:post, "https://secretsmanager.us-east-1.amazonaws.com/")
      .with(headers: {"X-Amz-Target" => "secretsmanager.PutSecretValue"})
      .to_return(body: %({"VersionId":"v-123","ARN":"arn:fake"}))

    version = fresh_client.put_secret_value("my-secret", "newpassword")
    version.version_id.should eq "v-123"
    version.secret_string.should eq "newpassword"
  end

  it "calls GetSecretValue and returns the value" do
    WebMock.stub(:post, "https://secretsmanager.us-east-1.amazonaws.com/")
      .with(headers: {"X-Amz-Target" => "secretsmanager.GetSecretValue"})
      .to_return(body: %({"VersionId":"v-1","SecretString":"theval"}))

    sv = fresh_client.get_secret_value("my-secret")
    sv.version_id.should eq "v-1"
    sv.secret_string.should eq "theval"
  end

  it "calls UpdateSecretVersionStage" do
    WebMock.stub(:post, "https://secretsmanager.us-east-1.amazonaws.com/")
      .with(headers: {"X-Amz-Target" => "secretsmanager.UpdateSecretVersionStage"})
      .to_return(body: "{}")

    fresh_client.update_secret_version_stage(
      "my-secret",
      "AWSCURRENT",
      move_to_version_id: "v2",
      remove_from_version_id: "v1",
    )
  end

  it "raises AwsApiError on HTTP non-2xx" do
    WebMock.stub(:post, "https://secretsmanager.us-east-1.amazonaws.com/")
      .to_return(status: 400, body: %({"__type":"ResourceNotFoundException","message":"nope"}))

    expect_raises(CRE::Aws::AwsApiError) do
      fresh_client.get_secret_value("missing")
    end
  end

  it "respects custom endpoint (LocalStack)" do
    WebMock.stub(:post, "http://localstack-test/")
      .with(headers: {"X-Amz-Target" => "secretsmanager.PutSecretValue"})
      .to_return(body: %({"VersionId":"local-v1"}))

    client = CRE::Aws::SecretsManagerClient.new(
      access_key_id: "test", secret_access_key: "test",
      region: "us-east-1", endpoint: "http://localstack-test:4566/",
    )
    client.put_secret_value("any", "val").version_id.should eq "local-v1"
  end
end
