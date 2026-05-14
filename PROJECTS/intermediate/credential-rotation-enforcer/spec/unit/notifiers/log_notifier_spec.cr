# ===================
# ©AngelaMos | 2026
# log_notifier_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/notifiers/log_notifier"
require "../../../src/cre/events/credential_events"

describe CRE::Notifiers::LogNotifier do
  it "subscribes and emits without errors on rotation events" do
    bus = CRE::Engine::EventBus.new
    notifier = CRE::Notifiers::LogNotifier.new(bus)
    notifier.start
    bus.run

    cred_id = UUID.random
    bus.publish CRE::Events::RotationCompleted.new(cred_id, UUID.random)
    bus.publish CRE::Events::RotationFailed.new(cred_id, UUID.random, "test")
    bus.publish CRE::Events::PolicyViolation.new(cred_id, "p", "stale")
    bus.publish CRE::Events::AlertRaised.new(CRE::Events::Severity::Warn, "hi")

    sleep 0.1.seconds
    notifier.stop
    bus.stop
  end
end
