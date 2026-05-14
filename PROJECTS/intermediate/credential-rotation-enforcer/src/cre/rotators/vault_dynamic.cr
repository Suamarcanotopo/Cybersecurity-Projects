# ===================
# ©AngelaMos | 2026
# vault_dynamic.cr
# ===================

require "json"
require "../vault/client"
require "./rotator"

module CRE::Rotators
  # VaultDynamicRotator manages dynamic-secrets-engine credentials in HashiCorp
  # Vault. Vault itself is the secret factory: we ask it for fresh creds and
  # revoke old leases on commit.
  #
  # Required Credential.tags:
  #   "role_path" - e.g. "database/creds/my-postgres-role"
  #   Optional "current_lease_id" - the lease to revoke on commit; if absent
  #   the rotator only revokes the NEW lease on rollback (apply step).
  class VaultDynamicRotator < Rotator
    register_as :vault_dynamic

    def initialize(@client : Vault::Client)
    end

    def kind : Symbol
      :vault_dynamic
    end

    def can_rotate?(c : Domain::Credential) : Bool
      c.kind.vault_dynamic? && !c.tag("role_path").nil?
    end

    def generate(c : Domain::Credential) : Domain::NewSecret
      raise RotatorError.new("missing 'role_path' tag") unless can_rotate?(c)
      role_path = c.tag("role_path").not_nil!
      ds = @client.read_dynamic(role_path)

      payload = {
        "username" => ds.username,
        "password" => ds.password,
      }.to_json

      Domain::NewSecret.new(
        ciphertext: payload.to_slice,
        metadata: {
          "lease_id"       => ds.lease_id,
          "lease_duration" => ds.lease_duration.to_s,
          "old_lease_id"   => c.tag("current_lease_id") || "",
          "username"       => ds.username,
        },
      )
    end

    def apply(c : Domain::Credential, s : Domain::NewSecret) : Nil
      _ = {c, s}
      # Vault already issued the new credentials and they're live. No-op.
    end

    def verify(c : Domain::Credential, s : Domain::NewSecret) : Bool
      _ = c
      lease_id = s.metadata["lease_id"]?
      return false if lease_id.nil? || lease_id.empty?
      # Lease renewal acts as a liveness check: if the lease is invalid Vault
      # will return non-2xx and we get an exception.
      @client.renew_lease(lease_id, increment: 0)
      true
    rescue
      false
    end

    def commit(c : Domain::Credential, s : Domain::NewSecret) : Nil
      _ = c
      old = s.metadata["old_lease_id"]?
      return if old.nil? || old.empty?
      @client.revoke_lease(old)
    end

    def rollback_apply(c : Domain::Credential, s : Domain::NewSecret) : Nil
      _ = c
      lease_id = s.metadata["lease_id"]?
      return if lease_id.nil? || lease_id.empty?
      @client.revoke_lease(lease_id) rescue nil
    end
  end
end
