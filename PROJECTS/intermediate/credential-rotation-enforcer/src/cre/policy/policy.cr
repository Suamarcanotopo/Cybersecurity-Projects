# ===================
# ©AngelaMos | 2026
# policy.cr
# ===================

require "../domain/credential"

module CRE::Policy
  enum Action
    RotateImmediately
    NotifyOnly
    Quarantine
  end

  enum Channel
    Telegram
    Email
    StructuredLog
    PagerDuty
  end

  enum Trigger
    OnRotationFailure
    OnDriftDetected
    OnPolicyViolation
  end

  alias Matcher = Domain::Credential -> Bool

  class Policy
    getter name : String
    getter description : String?
    getter matcher : Matcher
    getter max_age : Time::Span
    getter warn_at : Time::Span?
    getter enforce_action : Action
    getter notify_channels : Array(Channel)
    getter triggers : Hash(Trigger, Action)

    def initialize(
      @name : String,
      @description : String?,
      @matcher : Matcher,
      @max_age : Time::Span,
      @warn_at : Time::Span?,
      @enforce_action : Action,
      @notify_channels : Array(Channel),
      @triggers : Hash(Trigger, Action),
    )
    end

    def matches?(c : Domain::Credential) : Bool
      @matcher.call(c)
    end

    def overdue?(c : Domain::Credential, now : Time = Time.utc) : Bool
      (now - c.rotation_anchor) > @max_age
    end

    def in_warning_window?(c : Domain::Credential, now : Time = Time.utc) : Bool
      return false unless w = @warn_at
      age = now - c.rotation_anchor
      age > w && age <= @max_age
    end

    def trigger_action_for(trigger : Trigger) : Action?
      @triggers[trigger]?
    end
  end

  REGISTRY = [] of Policy

  def self.registry : Array(Policy)
    REGISTRY
  end

  def self.clear_registry! : Nil
    REGISTRY.clear
  end
end
