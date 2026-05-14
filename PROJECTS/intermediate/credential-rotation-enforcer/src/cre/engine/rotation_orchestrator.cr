# ===================
# ©AngelaMos | 2026
# rotation_orchestrator.cr
# ===================

require "log"
require "uuid"
require "./event_bus"
require "../events/credential_events"
require "../rotators/rotator"
require "../crypto/envelope"
require "../persistence/persistence"
require "../persistence/repos"

module CRE::Engine
  class VerifyFailed < Exception; end

  # The orchestrator drives a credential through the four-step rotation
  # contract (generate -> apply -> verify -> commit). On success it
  #   1. seals the new secret with the optional Envelope and writes a
  #      credential_versions row,
  #   2. bumps the credential's last_rotated_at and current/previous
  #      version pointers so the policy evaluator no longer sees it as
  #      overdue.
  #
  # Failures roll the credential back to its previous state. Failures in
  # apply or verify call rotator.rollback_apply; commit failures additionally
  # mark the rotation as Inconsistent because partial cloud-side stage
  # transitions cannot always be undone client-side.
  class RotationOrchestrator
    Log = ::Log.for("cre.rotator")

    def initialize(
      @bus : EventBus,
      @persistence : Persistence::Persistence,
      @envelope : Crypto::Envelope? = nil,
    )
    end

    def run(c : Domain::Credential, rotator : Rotators::Rotator) : Persistence::RotationState
      rotation_id = UUID.random
      record = Persistence::RotationRecord.new(
        id: rotation_id,
        credential_id: c.id,
        rotator_kind: kind_to_enum(rotator.kind),
        state: Persistence::RotationState::Generating,
        started_at: Time.utc,
        completed_at: nil,
        failure_reason: nil,
      )
      @persistence.rotations.insert(record)
      @bus.publish Events::RotationStarted.new(c.id, rotation_id, rotator.kind.to_s)

      new_secret = nil
      current_step = :generate
      begin
        @bus.publish Events::RotationStepStarted.new(c.id, rotation_id, :generate)
        new_secret = rotator.generate(c)
        @persistence.rotations.update_state(rotation_id, Persistence::RotationState::Applying)
        @bus.publish Events::RotationStepCompleted.new(c.id, rotation_id, :generate)

        current_step = :apply
        @bus.publish Events::RotationStepStarted.new(c.id, rotation_id, :apply)
        rotator.apply(c, new_secret)
        @persistence.rotations.update_state(rotation_id, Persistence::RotationState::Verifying)
        @bus.publish Events::RotationStepCompleted.new(c.id, rotation_id, :apply)

        current_step = :verify
        @bus.publish Events::RotationStepStarted.new(c.id, rotation_id, :verify)
        ok = rotator.verify(c, new_secret)
        raise VerifyFailed.new("verify returned false") unless ok
        @persistence.rotations.update_state(rotation_id, Persistence::RotationState::Committing)
        @bus.publish Events::RotationStepCompleted.new(c.id, rotation_id, :verify)

        current_step = :commit
        @bus.publish Events::RotationStepStarted.new(c.id, rotation_id, :commit)
        rotator.commit(c, new_secret)
        @bus.publish Events::RotationStepCompleted.new(c.id, rotation_id, :commit)

        finalize_success(c, new_secret, rotation_id)
        Persistence::RotationState::Completed
      rescue ex
        if (ns = new_secret) && (current_step == :apply || current_step == :verify)
          begin
            rotator.rollback_apply(c, ns)
          rescue rb
            Log.error(exception: rb) { "rollback_apply failed for credential #{c.id}" }
          end
        end
        finalize_failure(c, rotation_id, current_step, ex)
      end
    end

    private def finalize_success(c : Domain::Credential, secret : Domain::NewSecret, rotation_id : UUID) : Nil
      version_id = persist_credential_version(c, secret)
      bump_credential(c, version_id)
      @persistence.rotations.update_state(rotation_id, Persistence::RotationState::Completed)
      @bus.publish Events::RotationCompleted.new(c.id, rotation_id)
    end

    private def finalize_failure(
      c : Domain::Credential,
      rotation_id : UUID,
      current_step : Symbol,
      ex : Exception,
    ) : Persistence::RotationState
      reason = ex.message || ex.class.name
      terminal_state = current_step == :commit ? Persistence::RotationState::Inconsistent : Persistence::RotationState::Failed

      @persistence.rotations.update_state(rotation_id, terminal_state, reason)
      @bus.publish Events::RotationStepFailed.new(c.id, rotation_id, current_step, reason)
      @bus.publish Events::RotationFailed.new(c.id, rotation_id, reason)

      if terminal_state == Persistence::RotationState::Inconsistent
        @bus.publish Events::AlertRaised.new(
          severity: Events::Severity::Critical,
          message: "rotation #{rotation_id} for credential #{c.id} left in inconsistent state at commit step: #{reason}",
        )
      end

      terminal_state
    end

    private def persist_credential_version(c : Domain::Credential, secret : Domain::NewSecret) : UUID?
      env = @envelope
      return nil if env.nil?

      aad = "cred=#{c.id}|kind=#{c.kind}".to_slice
      sealed = env.seal(secret.ciphertext, aad)
      version = Domain::CredentialVersion.new(
        id: UUID.random,
        credential_id: c.id,
        ciphertext: sealed.ciphertext,
        dek_wrapped: sealed.dek_wrapped,
        kek_version: sealed.kek_version,
        algorithm_id: sealed.algorithm_id,
        metadata: secret.metadata,
        generated_at: secret.generated_at,
      )
      @persistence.versions.insert(version)
      version.id
    end

    private def bump_credential(c : Domain::Credential, new_version_id : UUID?) : Nil
      now = Time.utc
      updated = Domain::Credential.new(
        id: c.id,
        external_id: c.external_id,
        kind: c.kind,
        name: c.name,
        tags: c.tags,
        current_version_id: new_version_id || c.current_version_id,
        pending_version_id: nil,
        previous_version_id: new_version_id ? c.current_version_id : c.previous_version_id,
        created_at: c.created_at,
        updated_at: now,
        last_rotated_at: now,
      )
      @persistence.credentials.update(updated)
    end

    private def kind_to_enum(kind : Symbol) : Persistence::RotatorKind
      case kind
      when :aws_secretsmgr then Persistence::RotatorKind::AwsSecretsmgr
      when :vault_dynamic  then Persistence::RotatorKind::VaultDynamic
      when :github_pat     then Persistence::RotatorKind::GithubPat
      when :env_file       then Persistence::RotatorKind::EnvFile
      else                      raise "unknown rotator kind #{kind}"
      end
    end
  end
end
