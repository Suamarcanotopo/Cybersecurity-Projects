# ===================
# ©AngelaMos | 2026
# audit_log_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/audit/audit_log"
require "../../../src/cre/persistence/sqlite/sqlite_persistence"

describe CRE::Audit::AuditLog do
  it "appends and reads back entries with valid hash chain" do
    persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
    persist.migrate!
    log = CRE::Audit::AuditLog.new(persist, Bytes.new(32, 0_u8), 1, 1024)

    log.append("rotation.completed", "system", nil, {"x" => "y"})
    log.append("policy.violation", "system", nil, {"a" => "b"})

    persist.audit.latest_seq.should eq 2_i64
    log.verify_chain.should be_true
  ensure
    persist.try(&.close)
  end

  it "verify_chain detects when a row is tampered in DB directly" do
    persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
    persist.migrate!
    log = CRE::Audit::AuditLog.new(persist, Bytes.new(32, 0_u8), 1, 1024)

    log.append("a", "s", nil, {"k" => "v"})
    log.append("b", "s", nil, {"k" => "v2"})

    # The append-only trigger blocks tampering in the live DB; drop it
    # for this test so we can exercise the verify_chain code path against
    # a forced inconsistency.
    persist.db.exec("DROP TRIGGER audit_events_no_update")
    persist.db.exec("UPDATE audit_events SET payload = ? WHERE seq = 2", %({"event_type":"b","actor":"s","target_id":null,"payload":{"k":"BAD"}}))

    log.verify_chain.should be_false
  ensure
    persist.try(&.close)
  end

  it "append-only triggers exist on audit_events (SQLite)" do
    # The crystal-sqlite3 driver caches prepared statements at the connection
    # level; a failed UPDATE leaves the cached statement in error state and the
    # error re-surfaces at connection close, which conflates 'expect_raises'
    # bookkeeping. We verify the trigger by inspecting sqlite_master directly.
    persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
    persist.migrate!
    triggers = persist.db.query_all(
      "SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='audit_events'",
      as: String,
    )
    triggers.should contain "audit_events_no_update"
    triggers.should contain "audit_events_no_delete"
  ensure
    persist.try(&.close)
  end

  it "verify_chain returns true on empty log" do
    persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
    persist.migrate!
    log = CRE::Audit::AuditLog.new(persist, Bytes.new(32, 0_u8), 1, 1024)
    log.verify_chain.should be_true
  ensure
    persist.try(&.close)
  end

  it "ratchets version after configured threshold" do
    persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
    persist.migrate!
    log = CRE::Audit::AuditLog.new(persist, Bytes.new(32, 0_u8), 1, ratchet_every: 2)

    log.append("a", "s", nil, {"i" => "1"})
    log.append("a", "s", nil, {"i" => "2"})
    log.ratchet_version.should eq 1
    log.append("a", "s", nil, {"i" => "3"})
    log.ratchet_version.should eq 2
  ensure
    persist.try(&.close)
  end
end
