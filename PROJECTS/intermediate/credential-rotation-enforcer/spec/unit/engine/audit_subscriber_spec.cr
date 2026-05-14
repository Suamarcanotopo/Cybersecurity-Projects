# ===================
# ©AngelaMos | 2026
# audit_subscriber_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/engine/event_bus"
require "../../../src/cre/engine/subscribers/audit_subscriber"
require "../../../src/cre/audit/audit_log"
require "../../../src/cre/persistence/sqlite/sqlite_persistence"
require "../../../src/cre/events/credential_events"

describe CRE::Engine::Subscribers::AuditSubscriber do
  it "writes RotationCompleted events to the audit log" do
    persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
    persist.migrate!
    log = CRE::Audit::AuditLog.new(persist, Bytes.new(32, 0_u8), 1, 1024)

    bus = CRE::Engine::EventBus.new
    sub = CRE::Engine::Subscribers::AuditSubscriber.new(bus, log)
    sub.start
    bus.run

    cred_id = UUID.random
    rot_id = UUID.random
    bus.publish(CRE::Events::RotationCompleted.new(cred_id, rot_id))
    sleep 0.1.seconds

    persist.audit.latest_seq.should eq 1_i64
    entry = persist.audit.range(1_i64, 1_i64).first
    entry.event_type.should eq "rotation.completed"
    entry.target_id.should eq cred_id
  ensure
    bus.try(&.stop)
    sub.try(&.stop)
    persist.try(&.close)
  end

  it "writes multiple event types correctly" do
    persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
    persist.migrate!
    log = CRE::Audit::AuditLog.new(persist, Bytes.new(32, 0_u8), 1, 1024)
    bus = CRE::Engine::EventBus.new
    sub = CRE::Engine::Subscribers::AuditSubscriber.new(bus, log)
    sub.start
    bus.run

    cred_id = UUID.random
    bus.publish(CRE::Events::PolicyViolation.new(cred_id, "test-policy", "stale"))
    bus.publish(CRE::Events::DriftDetected.new(cred_id, "h1", "h2"))
    sleep 0.1.seconds

    persist.audit.latest_seq.should eq 2_i64
    entries = persist.audit.range(1_i64, 2_i64)
    entries.map(&.event_type).should eq ["policy.violation", "drift.detected"]
    log.verify_chain.should be_true
  ensure
    bus.try(&.stop)
    sub.try(&.stop)
    persist.try(&.close)
  end
end
