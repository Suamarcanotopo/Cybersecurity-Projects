# ===================
# ©AngelaMos | 2026
# evaluator_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/policy/evaluator"
require "../../../src/cre/policy/dsl"
require "../../../src/cre/persistence/sqlite/sqlite_persistence"

include CRE::Policy::Dsl

private def fresh_persistence
  persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
  persist.migrate!
  persist
end

# Drain non-blocking; returns whatever events arrived without waiting.
private def drain(ch : ::Channel(CRE::Events::Event)) : Array(CRE::Events::Event)
  out = [] of CRE::Events::Event
  loop do
    select
    when ev = ch.receive
      out << ev
    else
      break
    end
  end
  out
end

# Run the bus dispatcher inline for a few ticks so subscribers see events.
private def settle(bus : CRE::Engine::EventBus, duration : Time::Span = 0.1.seconds)
  sleep duration
end

describe CRE::Policy::Evaluator do
  before_each { CRE::Policy.clear_registry! }

  it "publishes PolicyViolation + RotationScheduled when overdue with rotate_immediately" do
    policy "test-rotate" do
      match { |c| c.kind.env_file? }
      max_age 7.days
      enforce :rotate_immediately
    end

    persist = fresh_persistence
    persist.credentials.insert(
      CRE::Domain::Credential.new(
        id: UUID.random, external_id: "x",
        kind: CRE::Domain::CredentialKind::EnvFile,
        name: "n", tags: {} of String => String,
        created_at: Time.utc - 30.days,
        updated_at: Time.utc - 30.days,
      )
    )

    bus = CRE::Engine::EventBus.new
    ch = bus.subscribe(buffer: 256, overflow: CRE::Engine::EventBus::Overflow::Block)
    bus.run

    CRE::Policy::Evaluator.new(bus, persist).evaluate_all
    settle(bus)

    events = drain(ch)
    types = events.map(&.class.name)
    types.should contain "CRE::Events::PolicyViolation"
    types.should contain "CRE::Events::RotationScheduled"
  ensure
    bus.try(&.stop)
    persist.try(&.close)
  end

  it "publishes AlertRaised for notify_only action" do
    policy "test-notify" do
      match { |c| c.kind.env_file? }
      max_age 7.days
      enforce :notify_only
    end

    persist = fresh_persistence
    persist.credentials.insert(
      CRE::Domain::Credential.new(
        id: UUID.random, external_id: "y",
        kind: CRE::Domain::CredentialKind::EnvFile,
        name: "n", tags: {} of String => String,
        created_at: Time.utc - 30.days, updated_at: Time.utc - 30.days,
      )
    )

    bus = CRE::Engine::EventBus.new
    ch = bus.subscribe(buffer: 256, overflow: CRE::Engine::EventBus::Overflow::Block)
    bus.run

    CRE::Policy::Evaluator.new(bus, persist).evaluate_all
    settle(bus)

    events = drain(ch)
    types = events.map(&.class.name)
    types.should contain "CRE::Events::PolicyViolation"
    types.should contain "CRE::Events::AlertRaised"
    types.should_not contain "CRE::Events::RotationScheduled"
  ensure
    bus.try(&.stop)
    persist.try(&.close)
  end

  it "does not fire for fresh credentials" do
    policy "test-fresh" do
      match { |c| c.kind.env_file? }
      max_age 30.days
      enforce :rotate_immediately
    end

    persist = fresh_persistence
    persist.credentials.insert(
      CRE::Domain::Credential.new(
        id: UUID.random, external_id: "f",
        kind: CRE::Domain::CredentialKind::EnvFile,
        name: "n", tags: {} of String => String,
      )
    )

    bus = CRE::Engine::EventBus.new
    ch = bus.subscribe(buffer: 256, overflow: CRE::Engine::EventBus::Overflow::Block)
    bus.run

    CRE::Policy::Evaluator.new(bus, persist).evaluate_all
    settle(bus)

    drain(ch).should be_empty
  ensure
    bus.try(&.stop)
    persist.try(&.close)
  end

  it "skips policies that don't match the credential" do
    policy "github-only" do
      match { |c| c.kind.github_pat? }
      max_age 7.days
      enforce :rotate_immediately
    end

    persist = fresh_persistence
    persist.credentials.insert(
      CRE::Domain::Credential.new(
        id: UUID.random, external_id: "envx",
        kind: CRE::Domain::CredentialKind::EnvFile,
        name: "n", tags: {} of String => String,
        updated_at: Time.utc - 30.days,
      )
    )

    bus = CRE::Engine::EventBus.new
    ch = bus.subscribe(buffer: 256, overflow: CRE::Engine::EventBus::Overflow::Block)
    bus.run

    CRE::Policy::Evaluator.new(bus, persist).evaluate_all
    settle(bus)

    drain(ch).should be_empty
  ensure
    bus.try(&.stop)
    persist.try(&.close)
  end
end
