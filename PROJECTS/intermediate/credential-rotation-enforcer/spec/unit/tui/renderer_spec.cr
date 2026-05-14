# ===================
# ©AngelaMos | 2026
# renderer_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/tui/renderer"
require "../../../src/cre/events/credential_events"

describe CRE::Tui::Renderer do
  it "renders the layout with header + panels" do
    state = CRE::Tui::State.new(kek_version: 3)
    io = IO::Memory.new
    CRE::Tui::Renderer.new(state, io, use_color: false).render

    out = CRE::Tui::Ansi.strip(io.to_s)
    out.should contain "Credential Rotation Enforcer"
    out.should contain "STATUS"
    out.should contain "Active Rotations"
    out.should contain "Recent Events"
    out.should contain "(no active rotations)"
    out.should contain "(no events yet)"
    out.should contain "v3"
  end

  it "renders active rotations" do
    state = CRE::Tui::State.new
    cred_id = UUID.random
    state.apply(CRE::Events::RotationStarted.new(cred_id, UUID.random, "aws_secretsmgr"))
    state.apply(CRE::Events::RotationStepCompleted.new(cred_id, UUID.random, :generate))
    state.apply(CRE::Events::RotationStepCompleted.new(cred_id, UUID.random, :apply))

    io = IO::Memory.new
    CRE::Tui::Renderer.new(state, io, use_color: false).render
    out = CRE::Tui::Ansi.strip(io.to_s)
    out.should contain "aws_secretsmgr"
    out.should contain "step 2/4"
  end

  it "renders recent events with timestamps" do
    state = CRE::Tui::State.new
    cred_id = UUID.random
    state.apply(CRE::Events::RotationCompleted.new(cred_id, UUID.random))
    state.apply(CRE::Events::PolicyViolation.new(cred_id, "p1", "stale"))

    io = IO::Memory.new
    CRE::Tui::Renderer.new(state, io, use_color: false).render
    out = CRE::Tui::Ansi.strip(io.to_s)
    out.should contain "rotation completed"
    out.should contain "p1"
  end
end
