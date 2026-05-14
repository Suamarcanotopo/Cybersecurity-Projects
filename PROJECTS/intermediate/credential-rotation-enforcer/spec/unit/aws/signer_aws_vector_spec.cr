# ===================
# ©AngelaMos | 2026
# signer_aws_vector_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/aws/signer"

# AWS publishes a reference SigV4 test suite at
# https://docs.aws.amazon.com/general/latest/gr/sigv4_signing.html with
# golden values for canonical request, string-to-sign, and signature.
#
# Our signer always emits X-Amz-Content-SHA256 (required by Secrets Manager
# and all the JSON-protocol services we target), which AWS's "vanilla"
# reference vectors deliberately omit. So instead of matching the vanilla
# vector byte-for-byte, we lock in:
#   1. The exact AWS-spec credential-scope and signed-headers list,
#   2. A regression-stable signature for a known input set with our
#      always-on X-Amz-Content-SHA256 header.
# Any change to canonicalization, key derivation, or header ordering
# breaks the regression vector — which is the failure mode we care about.
#
# Inputs match the published reference suite for everything except the
# extra signed header:
#   access_key:  AKIDEXAMPLE
#   secret_key:  wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY
#   region:      us-east-1
#   service:     service
#   date:        20150830T123600Z (UTC)
describe CRE::Aws::SigV4 do
  it "produces the AWS-spec credential-scope and signed-headers list" do
    signer = CRE::Aws::SigV4.new(
      access_key_id: "AKIDEXAMPLE",
      secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
      region: "us-east-1",
      service: "service",
    )

    headers = HTTP::Headers.new
    uri = URI.parse("https://example.amazonaws.com/")
    fixed_time = Time.utc(2015, 8, 30, 12, 36, 0)

    signer.sign("GET", uri, headers, "", fixed_time)

    headers["X-Amz-Date"].should eq "20150830T123600Z"
    headers["Host"].should eq "example.amazonaws.com"

    auth = headers["Authorization"]
    auth.should start_with "AWS4-HMAC-SHA256 "
    auth.should contain "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request"
    auth.should contain "SignedHeaders=host;x-amz-content-sha256;x-amz-date"
    auth.should match(/Signature=[a-f0-9]{64}\z/)
  end

  it "regression vector: locks in the bytewise signature for a fixed input" do
    signer = CRE::Aws::SigV4.new(
      access_key_id: "AKIDEXAMPLE",
      secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
      region: "us-east-1",
      service: "service",
    )
    headers = HTTP::Headers.new
    uri = URI.parse("https://example.amazonaws.com/")
    fixed_time = Time.utc(2015, 8, 30, 12, 36, 0)

    signer.sign("GET", uri, headers, "", fixed_time)

    # If any of canonicalization / key derivation / signed-headers
    # ordering / content-sha256 logic changes, this assertion catches it.
    expected = "726c5c4879a6b4ccbbd3b24edbd6b8826d34f87450fbbf4e85546fc7ba9c1642"
    headers["Authorization"].should contain "Signature=#{expected}"
  end

  it "matches a POST with body — content-sha256 changes the signature" do
    signer = CRE::Aws::SigV4.new(
      access_key_id: "AKIDEXAMPLE",
      secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
      region: "us-east-1",
      service: "service",
    )

    fixed_time = Time.utc(2015, 8, 30, 12, 36, 0)
    body = "Param1=value1"

    h_a = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}
    h_b = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}

    signer.sign("POST", URI.parse("https://example.amazonaws.com/"), h_a, body, fixed_time)
    signer.sign("POST", URI.parse("https://example.amazonaws.com/"), h_b, "different-body", fixed_time)

    # Two bodies, two different content-sha256 inputs, two different
    # signatures — proves the body actually flows into the signature.
    h_a["X-Amz-Content-SHA256"].should_not eq h_b["X-Amz-Content-SHA256"]
    h_a["Authorization"].should_not eq h_b["Authorization"]
  end

  it "different regions produce different signing keys (and signatures)" do
    east = CRE::Aws::SigV4.new("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "us-east-1", "service")
    west = CRE::Aws::SigV4.new("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "us-west-2", "service")
    fixed = Time.utc(2015, 8, 30, 12, 36, 0)

    h_e = HTTP::Headers.new
    h_w = HTTP::Headers.new
    east.sign("GET", URI.parse("https://example.amazonaws.com/"), h_e, "", fixed)
    west.sign("GET", URI.parse("https://example.amazonaws.com/"), h_w, "", fixed)

    h_e["Authorization"].should_not eq h_w["Authorization"]
  end

  it "session token participates in the signed-headers list" do
    signer = CRE::Aws::SigV4.new(
      access_key_id: "AKIDEXAMPLE",
      secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
      region: "us-east-1",
      service: "service",
      session_token: "TOKENVALUE",
    )
    h = HTTP::Headers.new
    fixed = Time.utc(2015, 8, 30, 12, 36, 0)
    signer.sign("GET", URI.parse("https://example.amazonaws.com/"), h, "", fixed)
    h["Authorization"].should contain "x-amz-security-token"
  end
end
