# ===================
# ©AngelaMos | 2026
# state_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/tui/state"
require "../../../src/cre/events/credential_events"

describe CRE::Tui::State do
  it "tracks active rotations through their step lifecycle" do
    state = CRE::Tui::State.new
    cred_id = UUID.random
    rot_id = UUID.random

    state.apply(CRE::Events::RotationStarted.new(cred_id, rot_id, "env_file"))
    state.active[cred_id]?.should_not be_nil
    state.active[cred_id].step.should eq "starting"
    state.active[cred_id].progress.should eq 0

    state.apply(CRE::Events::RotationStepCompleted.new(cred_id, rot_id, :generate))
    state.active[cred_id].progress.should eq 1
    state.active[cred_id].step.should eq "generate"

    state.apply(CRE::Events::RotationStepCompleted.new(cred_id, rot_id, :apply))
    state.apply(CRE::Events::RotationStepCompleted.new(cred_id, rot_id, :verify))
    state.apply(CRE::Events::RotationStepCompleted.new(cred_id, rot_id, :commit))
    state.active[cred_id].progress.should eq 4

    state.apply(CRE::Events::RotationCompleted.new(cred_id, rot_id))
    state.active.has_key?(cred_id).should be_false
    state.completed_24h.should eq 1
    state.recent.size.should eq 1
    state.recent.first.symbol.should eq "✓"
  end

  it "records failed rotations" do
    state = CRE::Tui::State.new
    cred_id = UUID.random
    state.apply(CRE::Events::RotationFailed.new(cred_id, UUID.random, "boom"))
    state.recent.first.symbol.should eq "!"
    state.recent.first.summary.should contain "FAILED"
  end

  it "trims recent events to MAX_RECENT_EVENTS" do
    state = CRE::Tui::State.new
    25.times do |i|
      state.apply(CRE::Events::AlertRaised.new(CRE::Events::Severity::Info, "msg-#{i}"))
    end
    state.recent.size.should eq CRE::Tui::State::MAX_RECENT_EVENTS
    state.recent.first.summary.should contain "msg-5"
    state.recent.last.summary.should contain "msg-24"
  end
end
