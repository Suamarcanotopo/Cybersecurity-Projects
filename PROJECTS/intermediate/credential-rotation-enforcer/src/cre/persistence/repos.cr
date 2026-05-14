# ===================
# ©AngelaMos | 2026
# repos.cr
# ===================

require "uuid"
require "../domain/credential"
require "../domain/credential_version"

module CRE::Persistence
  enum RotatorKind
    AwsSecretsmgr
    VaultDynamic
    GithubPat
    EnvFile
  end

  enum RotationState
    Pending
    Generating
    Applying
    Verifying
    Committing
    Completed
    Failed
    Aborted
    Inconsistent
  end

  TERMINAL_STATES = [RotationState::Completed, RotationState::Failed, RotationState::Aborted, RotationState::Inconsistent]

  record RotationRecord,
    id : UUID,
    credential_id : UUID,
    rotator_kind : RotatorKind,
    state : RotationState,
    started_at : Time,
    completed_at : Time?,
    failure_reason : String?

  record AuditEntry,
    seq : Int64,
    event_id : UUID,
    occurred_at : Time,
    event_type : String,
    actor : String,
    target_id : UUID?,
    payload : String,
    prev_hash : Bytes,
    content_hash : Bytes,
    hmac : Bytes,
    hmac_key_version : Int32

  record AuditBatch,
    id : UUID,
    start_seq : Int64,
    end_seq : Int64,
    merkle_root : Bytes,
    signature : Bytes,
    signing_key_version : Int32,
    sealed_at : Time

  abstract class CredentialsRepo
    abstract def insert(c : Domain::Credential) : Nil
    abstract def update(c : Domain::Credential) : Nil
    abstract def find(id : UUID) : Domain::Credential?
    abstract def find_by_external(kind : Domain::CredentialKind, external_id : String) : Domain::Credential?
    abstract def all : Array(Domain::Credential)
    abstract def overdue(now : Time, max_age : Time::Span) : Array(Domain::Credential)
  end

  abstract class VersionsRepo
    abstract def insert(v : Domain::CredentialVersion) : Nil
    abstract def find(id : UUID) : Domain::CredentialVersion?
    abstract def for_credential(credential_id : UUID) : Array(Domain::CredentialVersion)
    abstract def revoke(id : UUID, at : Time = Time.utc) : Nil
  end

  abstract class RotationsRepo
    abstract def insert(rotation : RotationRecord) : Nil
    abstract def update_state(id : UUID, state : RotationState, error : String? = nil) : Nil
    abstract def in_flight : Array(RotationRecord)
  end

  abstract class AuditRepo
    abstract def append(entry : AuditEntry) : Nil
    abstract def latest_hash : Bytes
    abstract def latest_seq : Int64
    abstract def range(start_seq : Int64, end_seq : Int64) : Array(AuditEntry)
    abstract def each_in_range(start_seq : Int64, end_seq : Int64, &block : AuditEntry ->) : Nil
    abstract def insert_batch(batch : AuditBatch) : Nil
    abstract def last_sealed_seq : Int64
    abstract def all_batches : Array(AuditBatch)
  end
end
