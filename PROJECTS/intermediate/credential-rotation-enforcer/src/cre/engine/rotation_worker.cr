# ===================
# ©AngelaMos | 2026
# rotation_worker.cr
# ===================

require "log"
require "./event_bus"
require "./rotation_orchestrator"
require "../events/credential_events"
require "../rotators/rotator"
require "../persistence/persistence"

module CRE::Engine
  # RotationWorker is the subscriber that turns RotationScheduled events into
  # actual 4-step rotations. It owns a kind -> Rotator dispatch table populated
  # at boot from env-var configuration (see cre run).
  #
  # The worker uses Block overflow so a slow rotator can't drop scheduled
  # rotations on the floor.
  class RotationWorker
    Log = ::Log.for("cre.rotation_worker")

    @ch : ::Channel(Events::Event)?
    @running : Bool
    @rotators : Hash(Symbol, Rotators::Rotator)

    def initialize(@bus : EventBus, @orchestrator : RotationOrchestrator, @persistence : Persistence::Persistence)
      @rotators = {} of Symbol => Rotators::Rotator
      @running = false
    end

    def register(kind : Symbol, rotator : Rotators::Rotator) : Nil
      @rotators[kind] = rotator
      Log.info { "registered rotator: #{kind}" }
    end

    def kinds : Array(Symbol)
      @rotators.keys
    end

    def rotator_for_kind(kind : Domain::CredentialKind) : Rotators::Rotator?
      @rotators[symbol_for_kind(kind)]?
    end

    def start : Nil
      @running = true
      ch = @bus.subscribe(buffer: 32, overflow: EventBus::Overflow::Block)
      @ch = ch
      spawn(name: "rotation-worker") do
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

    private def handle(ev : Events::Event) : Nil
      return unless ev.is_a?(Events::RotationScheduled)
      cred = @persistence.credentials.find(ev.credential_id)
      if cred.nil?
        Log.warn { "RotationScheduled for missing credential #{ev.credential_id}" }
        return
      end

      rotator_kind = symbol_for_kind(cred.kind)
      rotator = @rotators[rotator_kind]?
      if rotator.nil?
        Log.warn { "no rotator registered for #{rotator_kind} (credential #{cred.id}); skipping" }
        return
      end

      unless rotator.can_rotate?(cred)
        Log.warn { "rotator #{rotator_kind} declined credential #{cred.id} (missing required tags?)" }
        return
      end

      if @persistence.rotations.in_flight.any? { |r| r.credential_id == cred.id }
        Log.info { "rotation already in flight for credential #{cred.id}; skipping duplicate schedule" }
        return
      end

      @orchestrator.run(cred, rotator)
    rescue ex
      Log.error(exception: ex) { "rotation_worker.handle failed for event #{ev.class.name}" }
    end

    private def symbol_for_kind(k : Domain::CredentialKind) : Symbol
      case k
      in .aws_secretsmgr? then :aws_secretsmgr
      in .vault_dynamic?  then :vault_dynamic
      in .github_pat?     then :github_pat
      in .env_file?       then :env_file
      end
    end
  end
end
