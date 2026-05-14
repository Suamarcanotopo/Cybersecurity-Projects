# ===================
# ©AngelaMos | 2026
# postgres_persistence_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/persistence/postgres/postgres_persistence"

DATABASE_URL = ENV["DATABASE_URL"]? || "postgres://cre_test:cre_test@localhost:5433/cre_test"

private def fresh_persistence : CRE::Persistence::Postgres::PostgresPersistence
  persist = CRE::Persistence::Postgres::PostgresPersistence.new(DATABASE_URL)
  persist.migrate!
  persist.db.exec("TRUNCATE credentials, credential_versions, rotations CASCADE")
  persist.db.exec("ALTER TABLE audit_events DISABLE TRIGGER audit_events_no_update")
  persist.db.exec("DELETE FROM audit_events")
  persist.db.exec("ALTER TABLE audit_events ENABLE TRIGGER audit_events_no_update")
  persist.db.exec("DELETE FROM audit_batches")
  persist
end

describe CRE::Persistence::Postgres::PostgresPersistence do
  it "round-trips a credential through PG" do
    persist = fresh_persistence

    c = CRE::Domain::Credential.new(
      id: UUID.random,
      external_id: "pg-1",
      kind: CRE::Domain::CredentialKind::AwsSecretsmgr,
      name: "pg-test",
      tags: {"env" => "prod", "team" => "platform"} of String => String,
    )
    persist.credentials.insert(c)
    found = persist.credentials.find(c.id).not_nil!
    found.name.should eq "pg-test"
    found.tag("env").should eq "prod"
    found.tag("team").should eq "platform"
  ensure
    persist.try(&.close)
  end

  it "stores and retrieves binary credential versions" do
    persist = fresh_persistence

    cred = CRE::Domain::Credential.new(
      id: UUID.random, external_id: "pg-bin",
      kind: CRE::Domain::CredentialKind::EnvFile,
      name: "n", tags: {} of String => String,
    )
    persist.credentials.insert(cred)

    bytes = Bytes.new(64) { |i| i.to_u8 }
    v = CRE::Domain::CredentialVersion.new(
      id: UUID.random, credential_id: cred.id,
      ciphertext: bytes, dek_wrapped: Bytes[0xde, 0xad, 0xbe, 0xef],
      kek_version: 7, algorithm_id: 1_i16,
      metadata: {"version_id" => "abc"},
    )
    persist.versions.insert(v)
    found = persist.versions.find(v.id).not_nil!
    found.ciphertext.should eq bytes
    found.dek_wrapped.should eq Bytes[0xde, 0xad, 0xbe, 0xef]
    found.kek_version.should eq 7
    found.metadata["version_id"].should eq "abc"
  ensure
    persist.try(&.close)
  end

  it "audit_events trigger refuses UPDATE" do
    persist = fresh_persistence

    entry = CRE::Persistence::AuditEntry.new(
      seq: 0_i64, event_id: UUID.random, occurred_at: Time.utc,
      event_type: "test", actor: "system", target_id: nil,
      payload: %({"k":"v"}),
      prev_hash: Bytes.new(32, 0_u8),
      content_hash: Bytes.new(32, 0xaa_u8),
      hmac: Bytes.new(32, 0xbb_u8),
      hmac_key_version: 1,
    )
    persist.audit.append(entry)

    expect_raises(Exception, /append-only/) do
      persist.db.exec("UPDATE audit_events SET event_type = 'forged' WHERE seq = 1")
    end
  ensure
    persist.try(&.close)
  end

  it "advisory lock holds across the block" do
    persist = fresh_persistence
    counter = 0
    persist.with_advisory_lock(42_i64) do
      counter += 1
    end
    counter.should eq 1
  ensure
    persist.try(&.close)
  end
end
