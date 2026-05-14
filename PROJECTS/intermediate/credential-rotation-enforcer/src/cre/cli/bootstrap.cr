# ===================
# ©AngelaMos | 2026
# bootstrap.cr
# ===================

require "../crypto/kek"
require "../crypto/envelope"
require "../audit/signing"
require "../persistence/persistence"
require "../persistence/sqlite/sqlite_persistence"
require "../persistence/postgres/postgres_persistence"
require "../engine/rotation_worker"
require "../rotators/env_file"
require "../rotators/aws_secrets"
require "../rotators/vault_dynamic"
require "../rotators/github_pat"
require "../aws/secrets_client"
require "../vault/client"
require "../github/client"

module CRE::Cli::Bootstrap
  HMAC_KEY_VAR      = "CRE_HMAC_KEY_HEX"
  KEK_HEX_VAR       = "CRE_KEK_HEX"
  KEK_VERSION_VAR   = "CRE_KEK_VERSION"
  SIGNING_KEY_VAR   = "CRE_SIGNING_KEY_HEX"
  SEAL_INTERVAL_VAR = "CRE_SEAL_INTERVAL_SECONDS"

  class ConfigError < Exception; end

  # Loads the 32-byte HMAC seed key from CRE_HMAC_KEY_HEX. Hard-fails when
  # missing; the prior all-zero default left audit logs trivially forgeable
  # by anyone with read access to the source.
  def self.require_hmac_key : Bytes
    hex = ENV[HMAC_KEY_VAR]?
    if hex.nil? || hex.empty?
      raise ConfigError.new(
        "#{HMAC_KEY_VAR} is required for cre to start. Generate one with:\n  openssl rand -hex 32\nThen export it before invoking cre.",
      )
    end
    if hex.size != 64
      raise ConfigError.new("#{HMAC_KEY_VAR} must be 64 hex chars (32 bytes); got #{hex.size}")
    end
    hex.hexbytes
  end

  # Returns an Envelope when CRE_KEK_HEX is set; nil otherwise. nil disables
  # at-rest encryption — appropriate for the demo path, but cre run/watch
  # should refuse to start without it.
  def self.envelope : Crypto::Envelope?
    hex = ENV[KEK_HEX_VAR]?
    return nil if hex.nil? || hex.empty?
    raise ConfigError.new("#{KEK_HEX_VAR} must be 64 hex chars (32 bytes); got #{hex.size}") unless hex.size == 64
    version = (ENV[KEK_VERSION_VAR]? || "1").to_i
    kek = Crypto::Kek::EnvKek.new(KEK_HEX_VAR, version)
    Crypto::Envelope.new(kek)
  end

  def self.require_envelope : Crypto::Envelope
    env = envelope
    return env unless env.nil?
    raise ConfigError.new(
      "#{KEK_HEX_VAR} is required for cre run/watch. Generate with:\n  openssl rand -hex 32\nKEK rotation: bump #{KEK_VERSION_VAR}.",
    )
  end

  # Returns an Ed25519 signer when CRE_SIGNING_KEY_HEX is set, nil otherwise.
  # When nil, batch sealing is disabled and 'cre audit verify' will skip the
  # Merkle layer.
  def self.signer : Audit::Signing::Ed25519Signer?
    hex = ENV[SIGNING_KEY_VAR]?
    return nil if hex.nil? || hex.empty?
    raise ConfigError.new("#{SIGNING_KEY_VAR} must be 64 hex chars (32 bytes); got #{hex.size}") unless hex.size == 64
    Audit::Signing::Ed25519Signer.new(hex.hexbytes, version: 1)
  end

  def self.seal_interval : Time::Span
    seconds = (ENV[SEAL_INTERVAL_VAR]? || "300").to_i
    seconds.seconds
  end

  def self.build_persistence(url : String) : Persistence::Persistence
    if url.starts_with?("sqlite:")
      Persistence::Sqlite::SqlitePersistence.new(url.lchop("sqlite:"))
    elsif url.starts_with?("postgres://") || url.starts_with?("postgresql://")
      Persistence::Postgres::PostgresPersistence.new(url)
    else
      raise ConfigError.new("unknown database URL: #{url} (expected sqlite:PATH or postgres://...)")
    end
  end

  def self.register_rotators(worker : Engine::RotationWorker, io : IO) : Nil
    worker.register(:env_file, Rotators::EnvFileRotator.new)

    if (aws_id = ENV["AWS_ACCESS_KEY_ID"]?) && (aws_secret = ENV["AWS_SECRET_ACCESS_KEY"]?)
      client = Aws::SecretsManagerClient.new(
        access_key_id: aws_id,
        secret_access_key: aws_secret,
        region: ENV["AWS_REGION"]? || "us-east-1",
        endpoint: ENV["AWS_ENDPOINT"]?,
        session_token: ENV["AWS_SESSION_TOKEN"]?,
      )
      worker.register(:aws_secretsmgr, Rotators::AwsSecretsRotator.new(client))
    end

    if (vault_addr = ENV["VAULT_ADDR"]?) && (vault_token = ENV["VAULT_TOKEN"]?)
      client = Vault::Client.new(addr: vault_addr, token: vault_token)
      worker.register(:vault_dynamic, Rotators::VaultDynamicRotator.new(client))
    end

    if gh_token = ENV["GITHUB_TOKEN"]?
      api = ENV["GITHUB_API_BASE"]? || "https://api.github.com"
      client = Github::Client.new(token: gh_token, api_base: api)
      worker.register(:github_pat, Rotators::GithubPatRotator.new(client))
    end
  rescue ex
    io.puts "warning: rotator wiring failed: #{ex.message}"
  end

  def self.redact_db_url(url : String) : String
    url.gsub(/:\/\/[^:]+:[^@]+@/) { |_| "://****:****@" }
  end
end
