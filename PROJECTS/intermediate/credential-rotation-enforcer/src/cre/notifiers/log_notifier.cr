# ===================
# ©AngelaMos | 2026
# log_notifier.cr
# ===================

require "log"
require "../engine/event_bus"
require "../events/credential_events"
require "../events/system_events"

module CRE::Notifiers
  # LogNotifier subscribes to all events and emits structured stdlib Log lines.
  # Suitable for shipping to journald, vector, or fluentd; downstream tooling
  # can ingest the structured fields directly.
  class LogNotifier
    Log = ::Log.for("cre.notifier")

    @ch : ::Channel(Events::Event)?
    @running : Bool

    def initialize(@bus : Engine::EventBus)
      @running = false
    end

    def start : Nil
      @running = true
      ch = @bus.subscribe(buffer: 64, overflow: Engine::EventBus::Overflow::Drop)
      @ch = ch
      spawn(name: "log-notifier") do
        while @running
          begin
            ev = ch.receive
          rescue ::Channel::ClosedError
            break
          end
          emit(ev)
        end
      end
    end

    def stop : Nil
      @running = false
      @ch.try(&.close)
    end

    private def emit(ev : Events::Event) : Nil
      case ev
      when Events::RotationCompleted
        Log.info &.emit("rotation completed", credential_id: ev.credential_id.to_s, rotation_id: ev.rotation_id.to_s)
      when Events::RotationFailed
        Log.error &.emit("rotation failed", credential_id: ev.credential_id.to_s, rotation_id: ev.rotation_id.to_s, reason: ev.reason)
      when Events::PolicyViolation
        Log.warn &.emit("policy violation", credential_id: ev.credential_id.to_s, policy: ev.policy_name, reason: ev.reason)
      when Events::DriftDetected
        Log.warn &.emit("drift detected", credential_id: ev.credential_id.to_s, expected: ev.expected_hash, actual: ev.actual_hash)
      when Events::AlertRaised
        case ev.severity
        in Events::Severity::Critical then Log.error &.emit("alert", text: ev.message)
        in Events::Severity::Warn     then Log.warn &.emit("alert", text: ev.message)
        in Events::Severity::Info     then Log.info &.emit("alert", text: ev.message)
        end
      end
    end
  end
end
