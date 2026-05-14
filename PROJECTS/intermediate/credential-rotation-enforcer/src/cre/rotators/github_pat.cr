# ===================
# ©AngelaMos | 2026
# github_pat.cr
# ===================

require "json"
require "../github/client"
require "./rotator"

module CRE::Rotators
  # GithubPatRotator manages fine-grained Personal Access Tokens. It uses an
  # admin/issuer bearer to create the new PAT and to delete the old one.
  #
  # Required Credential.tags:
  #   "name"       - PAT label
  #   "old_pat_id" - the GitHub PAT id to revoke on commit
  #   "scopes"     - JSON-encoded array of scope strings (e.g. ["repo","read:org"])
  #   Optional "expires_in_days" - default 90
  class GithubPatRotator < Rotator
    register_as :github_pat

    def initialize(@client : Github::Client)
    end

    def kind : Symbol
      :github_pat
    end

    def can_rotate?(c : Domain::Credential) : Bool
      c.kind.github_pat? && !c.tag("name").nil? && !c.tag("scopes").nil?
    end

    def generate(c : Domain::Credential) : Domain::NewSecret
      raise RotatorError.new("missing 'name' or 'scopes' tag") unless can_rotate?(c)
      scopes = Array(String).from_json(c.tag("scopes").not_nil!)
      expires_in_days = (c.tag("expires_in_days") || "90").to_i

      new_token = @client.create_pat(c.tag("name").not_nil!, scopes, expires_in_days)

      Domain::NewSecret.new(
        ciphertext: new_token.token_value.to_slice,
        metadata: {
          "new_pat_id" => new_token.id.to_s,
          "old_pat_id" => c.tag("old_pat_id") || "",
          "expires_at" => new_token.expires_at || "",
        },
      )
    end

    def apply(c : Domain::Credential, s : Domain::NewSecret) : Nil
      _ = {c, s}
      # No-op: create_pat already exposed the token. Old PAT still works.
    end

    def verify(c : Domain::Credential, s : Domain::NewSecret) : Bool
      _ = c
      probe = Github::Client.new(String.new(s.ciphertext))
      probe.me
      true
    rescue
      false
    end

    def commit(c : Domain::Credential, s : Domain::NewSecret) : Nil
      _ = c
      old = s.metadata["old_pat_id"]?
      return if old.nil? || old.empty?
      @client.delete_pat(old.to_i64)
    end

    def rollback_apply(c : Domain::Credential, s : Domain::NewSecret) : Nil
      _ = c
      new_id = s.metadata["new_pat_id"]?
      return if new_id.nil? || new_id.empty?
      @client.delete_pat(new_id.to_i64) rescue nil
    end
  end
end
