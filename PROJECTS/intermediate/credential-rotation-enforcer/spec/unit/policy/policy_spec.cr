# ===================
# ©AngelaMos | 2026
# policy_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/policy/policy"

describe CRE::Policy::Policy do
  it "matches via the matcher" do
    p = CRE::Policy::Policy.new(
      name: "p1",
      description: nil,
      matcher: ->(c : CRE::Domain::Credential) { c.kind.env_file? },
      max_age: 30.days,
      warn_at: nil,
      enforce_action: CRE::Policy::Action::NotifyOnly,
      notify_channels: [] of CRE::Policy::Channel,
      triggers: {} of CRE::Policy::Trigger => CRE::Policy::Action,
    )

    matching = CRE::Domain::Credential.new(
      id: UUID.random, external_id: "x", kind: CRE::Domain::CredentialKind::EnvFile,
      name: "n", tags: {} of String => String,
    )
    other = CRE::Domain::Credential.new(
      id: UUID.random, external_id: "y", kind: CRE::Domain::CredentialKind::GithubPat,
      name: "n", tags: {} of String => String,
    )

    p.matches?(matching).should be_true
    p.matches?(other).should be_false
  end

  it "detects overdue based on rotation_anchor + max_age" do
    p = CRE::Policy::Policy.new(
      name: "p", description: nil,
      matcher: ->(_c : CRE::Domain::Credential) { true },
      max_age: 7.days, warn_at: nil,
      enforce_action: CRE::Policy::Action::NotifyOnly,
      notify_channels: [] of CRE::Policy::Channel,
      triggers: {} of CRE::Policy::Trigger => CRE::Policy::Action,
    )

    fresh = CRE::Domain::Credential.new(
      id: UUID.random, external_id: "f",
      kind: CRE::Domain::CredentialKind::EnvFile,
      name: "n", tags: {} of String => String,
      last_rotated_at: Time.utc - 1.day,
    )
    stale = CRE::Domain::Credential.new(
      id: UUID.random, external_id: "s",
      kind: CRE::Domain::CredentialKind::EnvFile,
      name: "n", tags: {} of String => String,
      last_rotated_at: Time.utc - 30.days,
    )

    p.overdue?(fresh).should be_false
    p.overdue?(stale).should be_true
  end

  it "treats never-rotated credentials by created_at" do
    p = CRE::Policy::Policy.new(
      name: "p", description: nil,
      matcher: ->(_c : CRE::Domain::Credential) { true },
      max_age: 7.days, warn_at: nil,
      enforce_action: CRE::Policy::Action::NotifyOnly,
      notify_channels: [] of CRE::Policy::Channel,
      triggers: {} of CRE::Policy::Trigger => CRE::Policy::Action,
    )

    aged = CRE::Domain::Credential.new(
      id: UUID.random, external_id: "a",
      kind: CRE::Domain::CredentialKind::EnvFile,
      name: "n", tags: {} of String => String,
      created_at: Time.utc - 30.days,
    )
    p.overdue?(aged).should be_true
  end

  it "ignores updated_at (renaming a credential does not reset rotation clock)" do
    p = CRE::Policy::Policy.new(
      name: "p", description: nil,
      matcher: ->(_c : CRE::Domain::Credential) { true },
      max_age: 7.days, warn_at: nil,
      enforce_action: CRE::Policy::Action::NotifyOnly,
      notify_channels: [] of CRE::Policy::Channel,
      triggers: {} of CRE::Policy::Trigger => CRE::Policy::Action,
    )

    just_renamed = CRE::Domain::Credential.new(
      id: UUID.random, external_id: "x",
      kind: CRE::Domain::CredentialKind::EnvFile,
      name: "n", tags: {} of String => String,
      created_at: Time.utc - 30.days,
      updated_at: Time.utc, # tag/name was just edited
      last_rotated_at: Time.utc - 30.days,
    )
    p.overdue?(just_renamed).should be_true
  end

  it "computes warning window" do
    p = CRE::Policy::Policy.new(
      name: "p", description: nil,
      matcher: ->(_c : CRE::Domain::Credential) { true },
      max_age: 30.days, warn_at: 25.days,
      enforce_action: CRE::Policy::Action::NotifyOnly,
      notify_channels: [] of CRE::Policy::Channel,
      triggers: {} of CRE::Policy::Trigger => CRE::Policy::Action,
    )

    young = CRE::Domain::Credential.new(
      id: UUID.random, external_id: "y", kind: CRE::Domain::CredentialKind::EnvFile,
      name: "n", tags: {} of String => String,
      last_rotated_at: Time.utc - 10.days,
    )
    warning = CRE::Domain::Credential.new(
      id: UUID.random, external_id: "w", kind: CRE::Domain::CredentialKind::EnvFile,
      name: "n", tags: {} of String => String,
      last_rotated_at: Time.utc - 27.days,
    )
    overdue = CRE::Domain::Credential.new(
      id: UUID.random, external_id: "o", kind: CRE::Domain::CredentialKind::EnvFile,
      name: "n", tags: {} of String => String,
      last_rotated_at: Time.utc - 31.days,
    )

    p.in_warning_window?(young).should be_false
    p.in_warning_window?(warning).should be_true
    p.in_warning_window?(overdue).should be_false
  end
end
