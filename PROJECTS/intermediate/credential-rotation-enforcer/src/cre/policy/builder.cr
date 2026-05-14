# ===================
# ©AngelaMos | 2026
# builder.cr
# ===================

require "./policy"

module CRE::Policy
  class BuilderError < Exception; end

  class Builder
    @name : String
    @description : String?
    @matcher : Matcher?
    @max_age : Time::Span?
    @warn_at : Time::Span?
    @enforce_action : Action?
    @notify_channels : Array(Channel)
    @triggers : Hash(Trigger, Action)

    def initialize(@name : String)
      @notify_channels = [] of Channel
      @triggers = {} of Trigger => Action
    end

    def description(text : String) : Nil
      @description = text
    end

    def match(&block : Domain::Credential -> Bool) : Nil
      @matcher = block
    end

    def max_age(span : Time::Span) : Nil
      @max_age = span
    end

    def warn_at(span : Time::Span) : Nil
      @warn_at = span
    end

    def enforce(action : Action) : Nil
      @enforce_action = action
    end

    def notify_via(*ch : Channel) : Nil
      ch.each { |c| @notify_channels << c }
    end

    def notify_via(*ch : Symbol) : Nil
      ch.each do |s|
        parsed = Channel.parse?(s.to_s)
        raise BuilderError.new("unknown channel '#{s}' in policy '#{@name}' (valid: #{Channel.values.map(&.to_s).join(", ")})") if parsed.nil?
        @notify_channels << parsed
      end
    end

    def on_rotation_failure(action : Action) : Nil
      @triggers[Trigger::OnRotationFailure] = action
    end

    def on_drift_detected(action : Action) : Nil
      @triggers[Trigger::OnDriftDetected] = action
    end

    def on_policy_violation(action : Action) : Nil
      @triggers[Trigger::OnPolicyViolation] = action
    end

    def build : Policy
      matcher = @matcher || raise BuilderError.new("policy '#{@name}' is missing match{} block")
      max_age = @max_age || raise BuilderError.new("policy '#{@name}' is missing max_age")
      enforce_action = @enforce_action || raise BuilderError.new("policy '#{@name}' is missing enforce")

      Policy.new(
        name: @name,
        description: @description,
        matcher: matcher,
        max_age: max_age,
        warn_at: @warn_at,
        enforce_action: enforce_action,
        notify_channels: @notify_channels,
        triggers: @triggers,
      )
    end
  end
end
