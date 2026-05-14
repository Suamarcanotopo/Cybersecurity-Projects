# ===================
# ©AngelaMos | 2026
# engine_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/engine/engine"
require "../../../src/cre/persistence/sqlite/sqlite_persistence"
require "../../../src/cre/events/credential_events"

describe CRE::Engine::Engine do
  it "boots, accepts events, and shuts down cleanly" do
    persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
    persist.migrate!

    engine = CRE::Engine::Engine.new(persist, Bytes.new(32, 0_u8))
    engine.start

    cred_id = UUID.random
    rot_id = UUID.random
    engine.bus.publish(CRE::Events::RotationCompleted.new(cred_id, rot_id))
    sleep 0.1.seconds

    persist.audit.latest_seq.should eq 1_i64
    engine.audit_log.verify_chain.should be_true

    engine.stop
  ensure
    persist.try(&.close)
  end

  it "raises if started twice" do
    persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
    persist.migrate!
    engine = CRE::Engine::Engine.new(persist, Bytes.new(32, 0_u8))
    engine.start
    expect_raises(Exception, "already started") { engine.start }
    engine.stop
  ensure
    persist.try(&.close)
  end
end
