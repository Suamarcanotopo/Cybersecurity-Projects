# ===================
# ©AngelaMos | 2026
# builder_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/policy/builder"

describe CRE::Policy::Builder do
  it "builds a complete policy" do
    b = CRE::Policy::Builder.new("p1")
    b.description("desc")
    b.match { |c| c.kind.env_file? }
    b.max_age(30.days)
    b.warn_at(25.days)
    b.enforce(CRE::Policy::Action::RotateImmediately)
    b.notify_via(CRE::Policy::Channel::Telegram, CRE::Policy::Channel::StructuredLog)
    b.on_rotation_failure(CRE::Policy::Action::Quarantine)

    p = b.build
    p.name.should eq "p1"
    p.description.should eq "desc"
    p.max_age.should eq 30.days
    p.warn_at.should eq 25.days
    p.enforce_action.should eq CRE::Policy::Action::RotateImmediately
    p.notify_channels.size.should eq 2
    p.trigger_action_for(CRE::Policy::Trigger::OnRotationFailure).should eq CRE::Policy::Action::Quarantine
  end

  it "raises on missing match" do
    b = CRE::Policy::Builder.new("p")
    b.max_age(7.days)
    b.enforce(CRE::Policy::Action::NotifyOnly)
    expect_raises(CRE::Policy::BuilderError, /match/) { b.build }
  end

  it "raises on missing max_age" do
    b = CRE::Policy::Builder.new("p")
    b.match { |_c| true }
    b.enforce(CRE::Policy::Action::NotifyOnly)
    expect_raises(CRE::Policy::BuilderError, /max_age/) { b.build }
  end

  it "raises on missing enforce" do
    b = CRE::Policy::Builder.new("p")
    b.match { |_c| true }
    b.max_age(7.days)
    expect_raises(CRE::Policy::BuilderError, /enforce/) { b.build }
  end
end
