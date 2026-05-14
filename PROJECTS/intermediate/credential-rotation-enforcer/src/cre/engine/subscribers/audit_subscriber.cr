# ===================
# ©AngelaMos | 2026
# audit_subscriber.cr
# ===================

require "../event_bus"
require "../../audit/audit_log"
require "../../events/credential_events"
require "../../events/system_events"

module CRE::Engine::Subscribers
  class AuditSubscriber
    @ch : Channel(Events::Event)?
    @running : Bool
    @drain_ready : ::Channel(Nil)

    def initialize(@bus : EventBus, @log : Audit::AuditLog, @actor : String = "system")
      @running = false
      @drain_ready = ::Channel(Nil).new(1)
    end

    def start : Nil
      @running = true
      ch = @bus.subscribe(buffer: 256, overflow: EventBus::Overflow::Block)
      @ch = ch
      spawn(name: "audit-sub") do
        while @running
          begin
            ev = ch.receive
          rescue Channel::ClosedError
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

    # Block until either the subscriber receives ShutdownRequested (i.e.
    # has drained everything published before the shutdown signal) or the
    # timeout elapses. Lets engine.stop deterministically wait instead of
    # sleeping for a magic 50ms.
    def await_drain(timeout_span : Time::Span = 2.seconds) : Bool
      select
      when @drain_ready.receive
        true
      when timeout(timeout_span)
        false
      end
    end

    private def handle(ev : Events::Event) : Nil
      case ev
      when Events::ShutdownRequested
        @drain_ready.send(nil) rescue nil
        return
      when Events::RotationCompleted
        @log.append("rotation.completed", @actor, ev.credential_id, {
          "rotation_id" => ev.rotation_id.to_s,
        })
      when Events::RotationFailed
        @log.append("rotation.failed", @actor, ev.credential_id, {
          "rotation_id" => ev.rotation_id.to_s,
          "reason"      => ev.reason,
        })
      when Events::RotationStepCompleted
        @log.append("rotation.step.completed", @actor, ev.credential_id, {
          "rotation_id" => ev.rotation_id.to_s,
          "step"        => ev.step.to_s,
        })
      when Events::RotationStepFailed
        @log.append("rotation.step.failed", @actor, ev.credential_id, {
          "rotation_id" => ev.rotation_id.to_s,
          "step"        => ev.step.to_s,
          "error"       => ev.error,
        })
      when Events::PolicyViolation
        @log.append("policy.violation", @actor, ev.credential_id, {
          "policy_name" => ev.policy_name,
          "reason"      => ev.reason,
        })
      when Events::DriftDetected
        @log.append("drift.detected", @actor, ev.credential_id, {
          "expected_hash" => ev.expected_hash,
          "actual_hash"   => ev.actual_hash,
        })
      when Events::CredentialDiscovered
        @log.append("credential.discovered", @actor, ev.credential_id, {} of String => String)
      when Events::AlertRaised
        @log.append("alert.raised", @actor, nil, {
          "severity" => ev.severity.to_s,
          "message"  => ev.message,
        })
      when Events::AuditBatchSealed
        @log.append("audit.batch.sealed", @actor, nil, {
          "start_seq"           => ev.start_seq.to_s,
          "end_seq"             => ev.end_seq.to_s,
          "signing_key_version" => ev.signing_key_version.to_s,
        })
      end
    rescue ex
      EventBus::Log.error(exception: ex) { "audit subscriber failed to write" }
      @bus.publish(Events::AlertRaised.new(
        severity: Events::Severity::Critical,
        message: "audit log write failed: #{ex.message} (event=#{ev.class.name})",
      )) rescue nil

      mode = ENV["CRE_AUDIT_FAILURE_MODE"]? || "panic"
      if mode == "panic"
        STDERR.puts "FATAL: audit log write failed in panic mode: #{ex.message} (event=#{ev.class.name})"
        Process.exit(2)
      end
    end
  end
end
