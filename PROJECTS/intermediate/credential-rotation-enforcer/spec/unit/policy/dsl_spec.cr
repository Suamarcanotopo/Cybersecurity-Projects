# ===================
# ©AngelaMos | 2026
# dsl_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/policy/dsl"

include CRE::Policy::Dsl

describe "Policy DSL" do
  before_each { CRE::Policy.clear_registry! }

  it "registers a policy with full DSL syntax" do
    policy "production-aws-secrets" do
      description "Prod AWS secret rotation"
      match { |c| c.kind.aws_secretsmgr? && c.tag(:env) == "prod" }
      max_age 30.days
      warn_at 25.days
      enforce :rotate_immediately
      notify_via :telegram, :structured_log
      on_rotation_failure :quarantine
    end

    CRE::Policy.registry.size.should eq 1
    p = CRE::Policy.registry.first
    p.name.should eq "production-aws-secrets"
    p.description.should eq "Prod AWS secret rotation"
    p.max_age.should eq 30.days
    p.warn_at.should eq 25.days
    p.enforce_action.should eq CRE::Policy::Action::RotateImmediately
    p.notify_channels.should contain(CRE::Policy::Channel::Telegram)
    p.trigger_action_for(CRE::Policy::Trigger::OnRotationFailure).should eq CRE::Policy::Action::Quarantine
  end

  it "supports symbol autocast for enum params" do
    policy "x" do
      match { |_c| true }
      max_age 1.day
      enforce :notify_only
      notify_via :email, :pagerduty
    end

    p = CRE::Policy.registry.first
    p.enforce_action.should eq CRE::Policy::Action::NotifyOnly
    p.notify_channels.should eq [CRE::Policy::Channel::Email, CRE::Policy::Channel::PagerDuty]
  end

  it "matcher is a real Crystal closure that captures state" do
    threshold = 100
    policy "captured" do
      match { |c| c.tags["score"]?.try(&.to_i.>=(threshold)) || false }
      max_age 1.day
      enforce :notify_only
    end

    p = CRE::Policy.registry.first
    above = CRE::Domain::Credential.new(
      id: UUID.random, external_id: "a", kind: CRE::Domain::CredentialKind::EnvFile,
      name: "n", tags: {"score" => "150"} of String => String,
    )
    below = CRE::Domain::Credential.new(
      id: UUID.random, external_id: "b", kind: CRE::Domain::CredentialKind::EnvFile,
      name: "n", tags: {"score" => "50"} of String => String,
    )
    p.matches?(above).should be_true
    p.matches?(below).should be_false
  end

  it "raises BuilderError for missing required fields" do
    expect_raises(CRE::Policy::BuilderError, /match/) do
      policy "incomplete" do
        max_age 1.day
        enforce :notify_only
      end
    end
  end
end
