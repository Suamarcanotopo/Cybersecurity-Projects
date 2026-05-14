# ===================
# ©AngelaMos | 2026
# signer_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/aws/signer"

# Reference SigV4 vector from AWS docs:
# https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-test-suite.html
# Using the well-known "get-vanilla" test vector adapted for our API.
describe CRE::Aws::SigV4 do
  it "signs a request idempotently for the same time" do
    signer = CRE::Aws::SigV4.new(
      access_key_id: "AKIDEXAMPLE",
      secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
      region: "us-east-1",
      service: "secretsmanager",
    )

    headers1 = HTTP::Headers{"Content-Type" => "application/x-amz-json-1.1"}
    headers2 = HTTP::Headers{"Content-Type" => "application/x-amz-json-1.1"}
    uri = URI.parse("https://secretsmanager.us-east-1.amazonaws.com/")
    body = %({"SecretId":"test"})
    fixed_time = Time.utc(2026, 4, 28, 12, 0, 0)

    signer.sign("POST", uri, headers1, body, fixed_time)
    signer.sign("POST", uri, headers2, body, fixed_time)

    headers1["Authorization"].should eq headers2["Authorization"]
  end

  it "produces a well-formed Authorization header" do
    signer = CRE::Aws::SigV4.new("AKID", "secret", "us-east-1", "secretsmanager")
    h = HTTP::Headers{"Content-Type" => "application/x-amz-json-1.1"}
    signer.sign("POST", URI.parse("https://secretsmanager.us-east-1.amazonaws.com/"), h, "{}")

    h["Authorization"].should match(/^AWS4-HMAC-SHA256 Credential=AKID\/\d{8}\/us-east-1\/secretsmanager\/aws4_request, SignedHeaders=[^,]+, Signature=[a-f0-9]{64}$/)
    h["X-Amz-Date"].should match(/^\d{8}T\d{6}Z$/)
    h["X-Amz-Content-SHA256"].size.should eq 64
    h["Host"].should eq "secretsmanager.us-east-1.amazonaws.com"
  end

  it "different bodies produce different signatures" do
    signer = CRE::Aws::SigV4.new("AKID", "secret", "us-east-1", "secretsmanager")
    h1 = HTTP::Headers{"Content-Type" => "application/x-amz-json-1.1"}
    h2 = HTTP::Headers{"Content-Type" => "application/x-amz-json-1.1"}
    uri = URI.parse("https://secretsmanager.us-east-1.amazonaws.com/")
    fixed = Time.utc(2026, 1, 1)

    signer.sign("POST", uri, h1, %({"a":1}), fixed)
    signer.sign("POST", uri, h2, %({"a":2}), fixed)
    h1["Authorization"].should_not eq h2["Authorization"]
  end

  it "includes session token header when provided" do
    signer = CRE::Aws::SigV4.new(
      access_key_id: "AKID",
      secret_access_key: "secret",
      region: "us-east-1",
      service: "secretsmanager",
      session_token: "FAKETOKEN",
    )
    h = HTTP::Headers{"Content-Type" => "application/x-amz-json-1.1"}
    signer.sign("POST", URI.parse("https://secretsmanager.us-east-1.amazonaws.com/"), h, "{}")
    h["X-Amz-Security-Token"].should eq "FAKETOKEN"
    h["Authorization"].should contain "x-amz-security-token"
  end
end
