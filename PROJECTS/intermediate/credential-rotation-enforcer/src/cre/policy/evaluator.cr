# ===================
# ©AngelaMos | 2026
# evaluator.cr
# ===================

require "log"
require "./policy"
require "../engine/event_bus"
require "../events/credential_events"
require "../events/system_events"
require "../persistence/persistence"

module CRE::Policy
  class PolicyConflictError < Exception; end

  class Evaluator
    Log = ::Log.for("cre.policy.evaluator")

    @ch : ::Channel(Events::Event)?
    @running : Bool

    def initialize(
      @bus : Engine::EventBus,
      @persistence : Persistence::Persistence,
      @policies : Array(Policy) = REGISTRY.dup,
    )
      @running = false
    end

    def start : Nil
      @running = true
      ch = @bus.subscribe(buffer: 64, overflow: Engine::EventBus::Overflow::Block)
      @ch = ch
      spawn(name: "policy-evaluator") do
        while @running
          begin
            ev = ch.receive
          rescue ::Channel::ClosedError
            break
          end
          handle(ev)
        end
      end
    end

    def stop : Nil
      @running = false
      @ch.try(&.close)
    end

    # evaluate_all groups policies by max_age and uses the persistence layer's
    # 'overdue' query so we don't pull every credential into memory each tick.
    def evaluate_all(now : Time = Time.utc) : Nil
      return if @policies.empty?

      seen = Set(UUID).new
      @policies.group_by(&.max_age).each do |max_age, policies_with_age|
        @persistence.credentials.overdue(now, max_age).each do |c|
          next if seen.includes?(c.id)
          seen << c.id
          evaluate(c, now)
        end
      end
    end

    # Evaluates a single credential. When more than one policy matches
    # we raise PolicyConflictError instead of silently picking by
    # registration order; conflicting policies are an operator bug, not
    # a runtime decision.
    def evaluate(c : Domain::Credential, now : Time = Time.utc) : Nil
      matching = @policies.select(&.matches?(c))
      return if matching.empty?

      if matching.size > 1
        names = matching.map(&.name).join(", ")
        @bus.publish Events::AlertRaised.new(
          severity: Events::Severity::Critical,
          message: "credential #{c.id} matches #{matching.size} policies (#{names}); refusing to act until ambiguity is resolved",
        )
        raise PolicyConflictError.new("credential #{c.id} matches #{matching.size} policies: #{names}")
      end

      policy = matching.first
      return unless policy.overdue?(c, now)

      @bus.publish Events::PolicyViolation.new(
        c.id,
        policy.name,
        "credential exceeded max_age=#{policy.max_age} (rotation_anchor #{c.rotation_anchor.to_rfc3339})",
      )

      case policy.enforce_action
      in Action::RotateImmediately
        @bus.publish Events::RotationScheduled.new(c.id, c.kind.to_s)
      in Action::NotifyOnly
        @bus.publish Events::AlertRaised.new(
          severity: Events::Severity::Warn,
          message: "policy '#{policy.name}' violated by credential '#{c.name}' (#{c.id})",
        )
      in Action::Quarantine
        @bus.publish Events::AlertRaised.new(
          severity: Events::Severity::Critical,
          message: "policy '#{policy.name}' triggered quarantine on credential '#{c.id}'",
        )
      end
    rescue ex : PolicyConflictError
      Log.error(exception: ex) { "policy conflict for #{c.id}" }
    rescue ex
      Log.error(exception: ex) { "policy evaluation failed for #{c.id}" }
    end

    private def handle(ev : Events::Event) : Nil
      case ev
      when Events::SchedulerTick
        evaluate_all
      when Events::CredentialDiscovered
        if c = @persistence.credentials.find(ev.credential_id)
          evaluate(c)
        end
      when Events::RotationCompleted
        if c = @persistence.credentials.find(ev.credential_id)
          evaluate(c)
        end
      end
    end
  end
end
