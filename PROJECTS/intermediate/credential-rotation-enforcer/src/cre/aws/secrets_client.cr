# ===================
# ©AngelaMos | 2026
# secrets_client.cr
# ===================

require "http/client"
require "json"
require "uuid"
require "./signer"
require "../http/retry"

module CRE::Aws
  class AwsApiError < Exception
    getter status : Int32
    getter aws_code : String?

    def initialize(message : String, @status : Int32, @aws_code : String? = nil)
      super(message)
    end
  end

  class SecretsManagerClient
    AWSCURRENT  = "AWSCURRENT"
    AWSPENDING  = "AWSPENDING"
    AWSPREVIOUS = "AWSPREVIOUS"

    record SecretVersion, version_id : String, secret_string : String?

    def initialize(
      @access_key_id : String,
      @secret_access_key : String,
      @region : String,
      @endpoint : String? = nil,
      @session_token : String? = nil,
    )
      @signer = SigV4.new(@access_key_id, @secret_access_key, @region, "secretsmanager", @session_token)
    end

    # Stages a new secret version with the AWSPENDING label.
    def put_secret_value(secret_id : String, secret_string : String, version_stages : Array(String) = [AWSPENDING]) : SecretVersion
      payload = {
        "SecretId"           => secret_id,
        "SecretString"       => secret_string,
        "ClientRequestToken" => UUID.random.to_s,
        "VersionStages"      => version_stages,
      }.to_json
      json = call("PutSecretValue", payload)
      SecretVersion.new(json["VersionId"].as_s, secret_string)
    end

    def get_secret_value(secret_id : String, version_id : String? = nil, version_stage : String? = nil) : SecretVersion
      payload_h = {"SecretId" => secret_id}
      payload_h["VersionId"] = version_id if version_id
      payload_h["VersionStage"] = version_stage if version_stage
      payload = payload_h.to_json
      json = call("GetSecretValue", payload)
      SecretVersion.new(
        json["VersionId"].as_s,
        json["SecretString"]?.try(&.as_s),
      )
    end

    def update_secret_version_stage(secret_id : String, version_stage : String, move_to_version_id : String? = nil, remove_from_version_id : String? = nil) : Nil
      payload_h = {
        "SecretId"     => secret_id,
        "VersionStage" => version_stage,
      }
      payload_h["MoveToVersionId"] = move_to_version_id if move_to_version_id
      payload_h["RemoveFromVersionId"] = remove_from_version_id if remove_from_version_id
      call("UpdateSecretVersionStage", payload_h.to_json)
    end

    private def call(action : String, body : String) : JSON::Any
      uri = URI.parse(@endpoint || "https://secretsmanager.#{@region}.amazonaws.com/")
      headers = HTTP::Headers{
        "Content-Type" => "application/x-amz-json-1.1",
        "X-Amz-Target" => "secretsmanager.#{action}",
      }
      @signer.sign("POST", uri, headers, body)

      response = CRE::Http.request("POST", uri.to_s, headers, body, label: "aws.#{action}")
      raise AwsApiError.new(error_message(response), response.status_code, error_code(response)) unless response.status_code < 300

      response.body.empty? ? JSON::Any.new(Hash(String, JSON::Any).new) : JSON.parse(response.body)
    end

    private def error_message(resp : HTTP::Client::Response) : String
      "AWS #{resp.status_code}: #{resp.body[0, 200]?}"
    end

    private def error_code(resp : HTTP::Client::Response) : String?
      return nil if resp.body.empty?
      JSON.parse(resp.body)["__type"]?.try(&.as_s)
    rescue
      nil
    end
  end
end
