# ===================
# ©AngelaMos | 2026
# aws_secrets.cr
# ===================

require "../aws/secrets_client"
require "../crypto/random"
require "./rotator"

module CRE::Rotators
  # AwsSecretsRotator implements the 4-step rotation contract against AWS Secrets
  # Manager, mirroring the standard Rotation Lambda template:
  #
  #   1. generate -> PutSecretValue with AWSPENDING label, returns version_id
  #   2. apply    -> no-op (PutSecretValue exposed it; AWSPENDING already attached)
  #   3. verify   -> GetSecretValue by version_id, confirm decoded value matches
  #   4. commit   -> UpdateSecretVersionStage move AWSCURRENT to new, AWSPREVIOUS to old
  #   rollback_apply -> remove AWSPENDING stage from the new version
  #
  # Required Credential.tags:
  #   "secret_arn"   - the AWS Secrets Manager ARN or name
  #   "value_length" - optional, bytes of random payload (default 32)
  class AwsSecretsRotator < Rotator
    register_as :aws_secretsmgr

    DEFAULT_BYTES = 32

    def initialize(@client : Aws::SecretsManagerClient)
    end

    def kind : Symbol
      :aws_secretsmgr
    end

    def can_rotate?(c : Domain::Credential) : Bool
      c.kind.aws_secretsmgr? && !c.tag("secret_arn").nil?
    end

    def generate(c : Domain::Credential) : Domain::NewSecret
      raise RotatorError.new("missing 'secret_arn' tag") unless can_rotate?(c)
      bytes = (c.tag("value_length") || DEFAULT_BYTES.to_s).to_i
      raw = CRE::Crypto::Random.bytes(bytes)
      new_value = Base64.urlsafe_encode(raw, padding: false)

      version = @client.put_secret_value(c.tag("secret_arn").not_nil!, new_value)
      Domain::NewSecret.new(
        ciphertext: new_value.to_slice,
        metadata: {
          "version_id" => version.version_id,
          "secret_arn" => c.tag("secret_arn").not_nil!,
        },
      )
    end

    def apply(c : Domain::Credential, s : Domain::NewSecret) : Nil
      _ = {c, s}
      # No-op: PutSecretValue with AWSPENDING already made the new version available.
    end

    def verify(c : Domain::Credential, s : Domain::NewSecret) : Bool
      version_id = s.metadata["version_id"]
      secret_arn = s.metadata["secret_arn"]
      retrieved = @client.get_secret_value(secret_arn, version_id: version_id)
      expected = String.new(s.ciphertext)
      retrieved.secret_string == expected
    rescue
      false
    end

    def commit(c : Domain::Credential, s : Domain::NewSecret) : Nil
      _ = c
      version_id = s.metadata["version_id"]
      secret_arn = s.metadata["secret_arn"]

      # Find the current version_id
      current = @client.get_secret_value(secret_arn, version_stage: Aws::SecretsManagerClient::AWSCURRENT)
      old_version_id = current.version_id

      # Move AWSCURRENT to new, removing it from old (atomic per AWS API)
      @client.update_secret_version_stage(
        secret_arn,
        Aws::SecretsManagerClient::AWSCURRENT,
        move_to_version_id: version_id,
        remove_from_version_id: old_version_id,
      )

      # Remove AWSPENDING from new version (it's now AWSCURRENT)
      @client.update_secret_version_stage(
        secret_arn,
        Aws::SecretsManagerClient::AWSPENDING,
        remove_from_version_id: version_id,
      ) rescue nil
    end

    def rollback_apply(c : Domain::Credential, s : Domain::NewSecret) : Nil
      _ = c
      version_id = s.metadata["version_id"]?
      secret_arn = s.metadata["secret_arn"]?
      return unless version_id && secret_arn
      @client.update_secret_version_stage(
        secret_arn,
        Aws::SecretsManagerClient::AWSPENDING,
        remove_from_version_id: version_id,
      ) rescue nil
    end
  end
end
