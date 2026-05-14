# ===================
# ©AngelaMos | 2026
# sqlite_persistence_spec.cr
# ===================

require "../../../spec_helper"
require "../../../../src/cre/persistence/sqlite/sqlite_persistence"

describe CRE::Persistence::Sqlite::SqlitePersistence do
  describe "credentials repo" do
    it "round-trips a credential" do
      persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
      persist.migrate!

      c = CRE::Domain::Credential.new(
        id: UUID.random,
        external_id: "ext-1",
        kind: CRE::Domain::CredentialKind::EnvFile,
        name: "test",
        tags: {"env" => "dev"} of String => String,
      )

      persist.credentials.insert(c)
      found = persist.credentials.find(c.id).not_nil!

      found.name.should eq "test"
      found.tag("env").should eq "dev"
      found.kind.env_file?.should be_true
    ensure
      persist.try(&.close)
    end

    it "find_by_external returns the right credential" do
      persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
      persist.migrate!

      c = CRE::Domain::Credential.new(
        id: UUID.random, external_id: "uniq-x",
        kind: CRE::Domain::CredentialKind::GithubPat,
        name: "n", tags: {} of String => String,
      )
      persist.credentials.insert(c)

      found = persist.credentials.find_by_external(
        CRE::Domain::CredentialKind::GithubPat, "uniq-x",
      ).not_nil!
      found.id.should eq c.id
    ensure
      persist.try(&.close)
    end

    it "all returns every credential" do
      persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
      persist.migrate!
      3.times do |i|
        persist.credentials.insert(
          CRE::Domain::Credential.new(
            id: UUID.random, external_id: "e#{i}",
            kind: CRE::Domain::CredentialKind::EnvFile,
            name: "n#{i}", tags: {} of String => String,
          )
        )
      end
      persist.credentials.all.size.should eq 3
    ensure
      persist.try(&.close)
    end

    it "update mutates name and tags" do
      persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
      persist.migrate!
      id = UUID.random
      persist.credentials.insert(
        CRE::Domain::Credential.new(
          id: id, external_id: "e", kind: CRE::Domain::CredentialKind::EnvFile,
          name: "before", tags: {} of String => String,
        )
      )
      persist.credentials.update(
        CRE::Domain::Credential.new(
          id: id, external_id: "e", kind: CRE::Domain::CredentialKind::EnvFile,
          name: "after", tags: {"k" => "v"} of String => String,
        )
      )
      found = persist.credentials.find(id).not_nil!
      found.name.should eq "after"
      found.tag("k").should eq "v"
    ensure
      persist.try(&.close)
    end
  end

  describe "versions repo" do
    it "round-trips a credential version with bytes" do
      persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
      persist.migrate!

      cred = CRE::Domain::Credential.new(
        id: UUID.random, external_id: "v-test",
        kind: CRE::Domain::CredentialKind::EnvFile,
        name: "v", tags: {} of String => String,
      )
      persist.credentials.insert(cred)

      v = CRE::Domain::CredentialVersion.new(
        id: UUID.random,
        credential_id: cred.id,
        ciphertext: Bytes[1, 2, 3, 4],
        dek_wrapped: Bytes[9, 8, 7],
        kek_version: 1,
        algorithm_id: 1_i16,
      )
      persist.versions.insert(v)

      found = persist.versions.find(v.id).not_nil!
      found.ciphertext.should eq Bytes[1, 2, 3, 4]
      found.dek_wrapped.should eq Bytes[9, 8, 7]
      found.algorithm_id.should eq 1_i16
    ensure
      persist.try(&.close)
    end

    it "revoke marks revoked_at" do
      persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
      persist.migrate!
      cred = CRE::Domain::Credential.new(
        id: UUID.random, external_id: "rev",
        kind: CRE::Domain::CredentialKind::EnvFile,
        name: "n", tags: {} of String => String,
      )
      persist.credentials.insert(cred)
      v = CRE::Domain::CredentialVersion.new(
        id: UUID.random, credential_id: cred.id,
        ciphertext: Bytes.new(0), dek_wrapped: Bytes.new(0),
        kek_version: 1, algorithm_id: 1_i16,
      )
      persist.versions.insert(v)
      persist.versions.revoke(v.id)

      found = persist.versions.find(v.id).not_nil!
      found.revoked?.should be_true
    ensure
      persist.try(&.close)
    end
  end

  describe "rotations repo" do
    it "tracks state transitions and in_flight filtering" do
      persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
      persist.migrate!
      cred_id = UUID.random
      persist.credentials.insert(
        CRE::Domain::Credential.new(
          id: cred_id, external_id: "rot", kind: CRE::Domain::CredentialKind::EnvFile,
          name: "n", tags: {} of String => String,
        )
      )

      r1 = CRE::Persistence::RotationRecord.new(
        id: UUID.random, credential_id: cred_id,
        rotator_kind: :env_file, state: :generating,
        started_at: Time.utc, completed_at: nil, failure_reason: nil,
      )
      r2 = CRE::Persistence::RotationRecord.new(
        id: UUID.random, credential_id: cred_id,
        rotator_kind: :env_file, state: :completed,
        started_at: Time.utc, completed_at: Time.utc, failure_reason: nil,
      )
      persist.rotations.insert(r1)
      persist.rotations.insert(r2)

      persist.rotations.in_flight.size.should eq 1
      persist.rotations.update_state(r1.id, :completed)
      persist.rotations.in_flight.size.should eq 0
    ensure
      persist.try(&.close)
    end
  end

  describe "audit repo" do
    it "appends and reads back entries; latest_hash returns genesis when empty" do
      persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
      persist.migrate!

      persist.audit.latest_hash.should eq CRE::Persistence::Sqlite::AuditRepo::GENESIS_HASH
      persist.audit.latest_seq.should eq 0_i64

      entry = CRE::Persistence::AuditEntry.new(
        seq: 0_i64, event_id: UUID.random,
        occurred_at: Time.utc, event_type: "test",
        actor: "system", target_id: nil,
        payload: %({"k":"v"}),
        prev_hash: Bytes.new(32, 0_u8),
        content_hash: Bytes.new(32, 0xaa_u8),
        hmac: Bytes.new(32, 0xbb_u8),
        hmac_key_version: 1,
      )
      persist.audit.append(entry)

      persist.audit.latest_seq.should eq 1_i64
      persist.audit.latest_hash.should eq Bytes.new(32, 0xaa_u8)
      rng = persist.audit.range(1_i64, 1_i64)
      rng.size.should eq 1
      rng[0].event_type.should eq "test"
    ensure
      persist.try(&.close)
    end
  end
end
