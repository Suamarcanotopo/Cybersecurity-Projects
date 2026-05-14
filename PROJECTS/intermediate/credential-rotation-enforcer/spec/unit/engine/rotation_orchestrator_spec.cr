# ===================
# ©AngelaMos | 2026
# rotation_orchestrator_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/engine/rotation_orchestrator"
require "../../../src/cre/persistence/sqlite/sqlite_persistence"
require "../../../src/cre/rotators/env_file"
require "../../../src/cre/crypto/envelope"
require "../../../src/cre/crypto/kek"

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

private def env_credential(path : String, key : String) : CRE::Domain::Credential
  CRE::Domain::Credential.new(
    id: UUID.random,
    external_id: "#{path}::#{key}",
    kind: CRE::Domain::CredentialKind::EnvFile,
    name: key,
    tags: {"path" => path, "key" => key} of String => String,
  )
end

describe CRE::Engine::RotationOrchestrator do
  it "publishes the full event sequence on success" do
    tmp = File.tempfile("cre_rot_") { |f| f << "K=v\n" }
    cred = env_credential(tmp.path, "K")

    persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
    persist.migrate!
    persist.credentials.insert(cred)

    bus = CRE::Engine::EventBus.new
    ch = bus.subscribe
    bus.run

    orchestrator = CRE::Engine::RotationOrchestrator.new(bus, persist)
    state = orchestrator.run(cred, CRE::Rotators::EnvFileRotator.new)

    sleep 0.1.seconds
    state.completed?.should be_true

    events = drain(ch).map(&.class.name)
    events.should contain "CRE::Events::RotationStarted"
    events.count("CRE::Events::RotationStepCompleted").should eq 4
    events.should contain "CRE::Events::RotationCompleted"
    events.should_not contain "CRE::Events::RotationFailed"

    # rotation row recorded as completed
    persist.rotations.in_flight.size.should eq 0
  ensure
    bus.try(&.stop)
    persist.try(&.close)
    tmp.try(&.delete)
  end

  it "handles a rotator that raises during apply via rollback" do
    tmp = File.tempfile("cre_rot_fail_") { |f| f << "K=v\n" }
    cred = env_credential(tmp.path, "K")

    persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
    persist.migrate!
    persist.credentials.insert(cred)

    bus = CRE::Engine::EventBus.new
    ch = bus.subscribe
    bus.run

    failing = FailingRotator.new
    state = CRE::Engine::RotationOrchestrator.new(bus, persist).run(cred, failing)
    sleep 0.1.seconds

    state.failed?.should be_true
    failing.rolled_back.should be_true

    events = drain(ch).map(&.class.name)
    events.should contain "CRE::Events::RotationStepFailed"
    events.should contain "CRE::Events::RotationFailed"
  ensure
    bus.try(&.stop)
    persist.try(&.close)
    tmp.try(&.delete)
  end

  it "bumps credential.last_rotated_at on successful rotation" do
    tmp = File.tempfile("cre_rot_anchor_") { |f| f << "K=v\n" }
    cred = env_credential(tmp.path, "K")
    persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
    persist.migrate!
    persist.credentials.insert(cred)

    bus = CRE::Engine::EventBus.new
    bus.run

    floor = Time.utc.at_beginning_of_second
    state = CRE::Engine::RotationOrchestrator.new(bus, persist).run(cred, CRE::Rotators::EnvFileRotator.new)
    sleep 0.05.seconds
    state.completed?.should be_true

    refreshed = persist.credentials.find(cred.id).not_nil!
    refreshed.last_rotated_at.not_nil!.should be >= floor
    refreshed.rotation_anchor.should be >= floor
  ensure
    bus.try(&.stop)
    persist.try(&.close)
    tmp.try(&.delete)
  end

  it "writes an encrypted credential_version when an Envelope is configured" do
    ENV["TEST_KEK_ROT"] = "0" * 64
    kek = CRE::Crypto::Kek::EnvKek.new("TEST_KEK_ROT", version: 1)
    envelope = CRE::Crypto::Envelope.new(kek)

    tmp = File.tempfile("cre_rot_env_") { |f| f << "K=v\n" }
    cred = env_credential(tmp.path, "K")
    persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
    persist.migrate!
    persist.credentials.insert(cred)

    bus = CRE::Engine::EventBus.new
    bus.run

    state = CRE::Engine::RotationOrchestrator.new(bus, persist, envelope).run(cred, CRE::Rotators::EnvFileRotator.new)
    sleep 0.05.seconds
    state.completed?.should be_true

    versions = persist.versions.for_credential(cred.id)
    versions.size.should eq 1
    v = versions.first
    v.kek_version.should eq 1
    v.algorithm_id.should eq CRE::Crypto::ALGORITHM_AES_256_GCM
    v.ciphertext.size.should be > 0

    sealed = CRE::Crypto::SealedSecret.new(v.ciphertext, v.dek_wrapped, v.kek_version, v.algorithm_id)
    plaintext = envelope.open(sealed, "cred=#{cred.id}|kind=#{cred.kind}".to_slice)
    plaintext.size.should be > 0

    refreshed = persist.credentials.find(cred.id).not_nil!
    refreshed.current_version_id.should eq v.id
  ensure
    ENV.delete("TEST_KEK_ROT")
    bus.try(&.stop)
    persist.try(&.close)
    tmp.try(&.delete)
  end

  it "marks rotation Inconsistent when commit step fails" do
    tmp = File.tempfile("cre_rot_commit_fail_") { |f| f << "K=v\n" }
    cred = env_credential(tmp.path, "K")
    persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
    persist.migrate!
    persist.credentials.insert(cred)

    bus = CRE::Engine::EventBus.new
    ch = bus.subscribe
    bus.run

    state = CRE::Engine::RotationOrchestrator.new(bus, persist).run(cred, CommitFailingRotator.new)
    sleep 0.05.seconds

    state.should eq CRE::Persistence::RotationState::Inconsistent
    persist.rotations.in_flight.size.should eq 0

    types = drain(ch).map(&.class.name)
    types.should contain "CRE::Events::AlertRaised"
  ensure
    bus.try(&.stop)
    persist.try(&.close)
    tmp.try(&.delete)
  end
end

class CommitFailingRotator < CRE::Rotators::Rotator
  def kind : Symbol
    :env_file
  end

  def can_rotate?(c : CRE::Domain::Credential) : Bool
    _ = c
    true
  end

  def generate(c : CRE::Domain::Credential) : CRE::Domain::NewSecret
    _ = c
    CRE::Domain::NewSecret.new(ciphertext: "x".to_slice)
  end

  def apply(c : CRE::Domain::Credential, s : CRE::Domain::NewSecret) : Nil
    _ = {c, s}
  end

  def verify(c : CRE::Domain::Credential, s : CRE::Domain::NewSecret) : Bool
    _ = {c, s}
    true
  end

  def commit(c : CRE::Domain::Credential, s : CRE::Domain::NewSecret) : Nil
    _ = {c, s}
    raise CRE::Rotators::RotatorError.new("commit network 503")
  end
end

class FailingRotator < CRE::Rotators::Rotator
  property rolled_back = false

  def kind : Symbol
    :env_file
  end

  def can_rotate?(c : CRE::Domain::Credential) : Bool
    _ = c
    true
  end

  def generate(c : CRE::Domain::Credential) : CRE::Domain::NewSecret
    _ = c
    CRE::Domain::NewSecret.new(ciphertext: "x".to_slice)
  end

  def apply(c : CRE::Domain::Credential, s : CRE::Domain::NewSecret) : Nil
    _ = {c, s}
    raise CRE::Rotators::RotatorError.new("apply boom")
  end

  def verify(c : CRE::Domain::Credential, s : CRE::Domain::NewSecret) : Bool
    _ = {c, s}
    true
  end

  def commit(c : CRE::Domain::Credential, s : CRE::Domain::NewSecret) : Nil
    _ = {c, s}
  end

  def rollback_apply(c : CRE::Domain::Credential, s : CRE::Domain::NewSecret) : Nil
    _ = {c, s}
    @rolled_back = true
  end
end
