# ===================
# ©AngelaMos | 2026
# batch_sealer_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/audit/audit_log"
require "../../../src/cre/audit/batch_sealer"
require "../../../src/cre/audit/signing"
require "../../../src/cre/persistence/sqlite/sqlite_persistence"

describe CRE::Audit::BatchSealer do
  it "seals pending audit events into a signed Merkle batch" do
    persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
    persist.migrate!

    log = CRE::Audit::AuditLog.new(persist, Bytes.new(32, 0_u8), 1, 1024)
    log.append("a", "s", nil, {"i" => "1"})
    log.append("b", "s", nil, {"i" => "2"})
    log.append("c", "s", nil, {"i" => "3"})

    kp = CRE::Audit::Signing::Ed25519Keypair.generate(version: 1)
    signer = CRE::Audit::Signing::Ed25519Signer.from_keypair(kp)
    sealer = CRE::Audit::BatchSealer.new(persist, signer)

    batch = sealer.seal_pending.not_nil!
    batch.start_seq.should eq 1_i64
    batch.end_seq.should eq 3_i64
    batch.signing_key_version.should eq 1
    batch.merkle_root.size.should eq 32
    batch.signature.size.should eq 64

    verifier = CRE::Audit::Signing::Ed25519Verifier.new(kp.public_key)
    msg = CRE::Audit::BatchSealer.pack_message(batch.start_seq, batch.end_seq, batch.merkle_root)
    verifier.verify(msg, batch.signature).should be_true

    persist.audit.last_sealed_seq.should eq 3_i64
  ensure
    persist.try(&.close)
  end

  it "returns nil when nothing pending" do
    persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
    persist.migrate!

    kp = CRE::Audit::Signing::Ed25519Keypair.generate
    signer = CRE::Audit::Signing::Ed25519Signer.from_keypair(kp)
    sealer = CRE::Audit::BatchSealer.new(persist, signer)
    sealer.seal_pending.should be_nil
  ensure
    persist.try(&.close)
  end

  it "subsequent seal covers only new events" do
    persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
    persist.migrate!
    log = CRE::Audit::AuditLog.new(persist, Bytes.new(32, 0_u8), 1, 1024)
    kp = CRE::Audit::Signing::Ed25519Keypair.generate
    signer = CRE::Audit::Signing::Ed25519Signer.from_keypair(kp)
    sealer = CRE::Audit::BatchSealer.new(persist, signer)

    log.append("a", "s", nil, {"i" => "1"})
    log.append("b", "s", nil, {"i" => "2"})
    sealer.seal_pending.not_nil!.end_seq.should eq 2_i64

    log.append("c", "s", nil, {"i" => "3"})
    second = sealer.seal_pending.not_nil!
    second.start_seq.should eq 3_i64
    second.end_seq.should eq 3_i64
  ensure
    persist.try(&.close)
  end
end
