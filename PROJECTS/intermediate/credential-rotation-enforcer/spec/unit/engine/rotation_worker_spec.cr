# ===================
# ©AngelaMos | 2026
# rotation_worker_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/engine/event_bus"
require "../../../src/cre/engine/rotation_worker"
require "../../../src/cre/engine/rotation_orchestrator"
require "../../../src/cre/persistence/sqlite/sqlite_persistence"
require "../../../src/cre/rotators/env_file"

private def env_credential(path : String, key : String) : CRE::Domain::Credential
  CRE::Domain::Credential.new(
    id: UUID.random,
    external_id: "#{path}::#{key}",
    kind: CRE::Domain::CredentialKind::EnvFile,
    name: key,
    tags: {"path" => path, "key" => key} of String => String,
  )
end

private def setup_worker
  persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
  persist.migrate!
  bus = CRE::Engine::EventBus.new
  bus.run
  orchestrator = CRE::Engine::RotationOrchestrator.new(bus, persist)
  worker = CRE::Engine::RotationWorker.new(bus, orchestrator, persist)
  {persist, bus, worker}
end

class StubRotator < CRE::Rotators::Rotator
  property generate_count = 0
  property apply_count = 0
  property commit_count = 0
  property declined_credentials = [] of UUID

  def initialize(@kind_sym : Symbol = :env_file, @can_rotate : Bool = true)
  end

  def kind : Symbol
    @kind_sym
  end

  def can_rotate?(c : CRE::Domain::Credential) : Bool
    @declined_credentials << c.id unless @can_rotate
    @can_rotate
  end

  def generate(c : CRE::Domain::Credential) : CRE::Domain::NewSecret
    _ = c
    @generate_count += 1
    CRE::Domain::NewSecret.new(ciphertext: "x".to_slice)
  end

  def apply(c : CRE::Domain::Credential, s : CRE::Domain::NewSecret) : Nil
    _ = {c, s}
    @apply_count += 1
  end

  def verify(c : CRE::Domain::Credential, s : CRE::Domain::NewSecret) : Bool
    _ = {c, s}
    true
  end

  def commit(c : CRE::Domain::Credential, s : CRE::Domain::NewSecret) : Nil
    _ = {c, s}
    @commit_count += 1
  end
end

describe CRE::Engine::RotationWorker do
  it "dispatches RotationScheduled to the registered rotator" do
    persist, bus, worker = setup_worker
    persist.credentials.insert(env_credential("/tmp/x.env", "K"))
    rotator = StubRotator.new
    worker.register(:env_file, rotator)
    worker.start

    cred = persist.credentials.all.first
    bus.publish CRE::Events::RotationScheduled.new(cred.id, "env_file")
    sleep 0.15.seconds

    rotator.generate_count.should eq 1
  ensure
    worker.try(&.stop)
    bus.try(&.stop)
    persist.try(&.close)
  end

  it "skips when no rotator is registered for the credential's kind" do
    persist, bus, worker = setup_worker
    persist.credentials.insert(env_credential("/tmp/y.env", "K"))
    worker.start

    cred = persist.credentials.all.first
    bus.publish CRE::Events::RotationScheduled.new(cred.id, "env_file")
    sleep 0.1.seconds

    persist.rotations.in_flight.size.should eq 0
  ensure
    worker.try(&.stop)
    bus.try(&.stop)
    persist.try(&.close)
  end

  it "skips when rotator.can_rotate? returns false" do
    persist, bus, worker = setup_worker
    persist.credentials.insert(env_credential("/tmp/z.env", "K"))
    rotator = StubRotator.new(can_rotate: false)
    worker.register(:env_file, rotator)
    worker.start

    cred = persist.credentials.all.first
    bus.publish CRE::Events::RotationScheduled.new(cred.id, "env_file")
    sleep 0.1.seconds

    rotator.generate_count.should eq 0
    rotator.declined_credentials.should contain(cred.id)
  ensure
    worker.try(&.stop)
    bus.try(&.stop)
    persist.try(&.close)
  end

  it "ignores events that aren't RotationScheduled" do
    persist, bus, worker = setup_worker
    persist.credentials.insert(env_credential("/tmp/w.env", "K"))
    rotator = StubRotator.new
    worker.register(:env_file, rotator)
    worker.start

    cred = persist.credentials.all.first
    bus.publish CRE::Events::RotationCompleted.new(cred.id, UUID.random)
    sleep 0.1.seconds

    rotator.generate_count.should eq 0
  ensure
    worker.try(&.stop)
    bus.try(&.stop)
    persist.try(&.close)
  end

  it "deduplicates: a duplicate schedule while one is in_flight is dropped" do
    persist, bus, worker = setup_worker
    persist.credentials.insert(env_credential("/tmp/dedup.env", "K"))
    cred = persist.credentials.all.first

    record = CRE::Persistence::RotationRecord.new(
      id: UUID.random,
      credential_id: cred.id,
      rotator_kind: CRE::Persistence::RotatorKind::EnvFile,
      state: CRE::Persistence::RotationState::Generating,
      started_at: Time.utc,
      completed_at: nil,
      failure_reason: nil,
    )
    persist.rotations.insert(record)

    rotator = StubRotator.new
    worker.register(:env_file, rotator)
    worker.start

    bus.publish CRE::Events::RotationScheduled.new(cred.id, "env_file")
    sleep 0.1.seconds

    rotator.generate_count.should eq 0 # blocked by in_flight check
  ensure
    worker.try(&.stop)
    bus.try(&.stop)
    persist.try(&.close)
  end

  it "warns and skips when credential is missing from persistence" do
    persist, bus, worker = setup_worker
    rotator = StubRotator.new
    worker.register(:env_file, rotator)
    worker.start

    bus.publish CRE::Events::RotationScheduled.new(UUID.random, "env_file")
    sleep 0.1.seconds

    rotator.generate_count.should eq 0
  ensure
    worker.try(&.stop)
    bus.try(&.stop)
    persist.try(&.close)
  end

  it "rotator_for_kind returns nil for unregistered kinds" do
    _, _, worker = setup_worker
    worker.register(:env_file, StubRotator.new)
    worker.rotator_for_kind(CRE::Domain::CredentialKind::EnvFile).should_not be_nil
    worker.rotator_for_kind(CRE::Domain::CredentialKind::AwsSecretsmgr).should be_nil
  end
end
