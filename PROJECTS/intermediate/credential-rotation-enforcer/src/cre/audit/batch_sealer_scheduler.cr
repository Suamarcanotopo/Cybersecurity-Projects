# ===================
# ©AngelaMos | 2026
# batch_sealer_scheduler.cr
# ===================

require "log"
require "./batch_sealer"
require "../engine/event_bus"
require "../events/credential_events"
require "../events/system_events"

module CRE::Audit
  # BatchSealerScheduler runs an idle fiber that periodically calls
  # BatchSealer.seal_pending. Without this fiber the audit_batches table
  # never grows and 'cre audit verify --merkle' has nothing to verify.
  #
  # On each successful seal we publish AlertRaised(:info) with the sealed
  # range; the AuditSubscriber then writes a 'audit.batch.sealed' event
  # into the audit log itself, which closes the loop for compliance
  # frameworks that key on that event_type.
  class BatchSealerScheduler
    Log = ::Log.for("cre.batch_sealer")

    @running : Bool

    def initialize(@bus : Engine::EventBus, @sealer : BatchSealer, @interval : Time::Span = 5.minutes)
      @running = false
    end

    def start : Nil
      @running = true
      spawn(name: "batch-sealer") do
        seal_once
        while @running
          sleep @interval
          break unless @running
          seal_once
        end
      end
    end

    def stop : Nil
      @running = false
      seal_once # final seal on shutdown
    end

    def seal_once : Nil
      batch = @sealer.seal_pending
      return if batch.nil?

      @bus.publish Events::AuditBatchSealed.new(
        start_seq: batch.start_seq,
        end_seq: batch.end_seq,
        signing_key_version: batch.signing_key_version,
      )
    rescue ex
      Log.error(exception: ex) { "batch_sealer.seal_pending failed" }
      @bus.publish(Events::AlertRaised.new(
        severity: Events::Severity::Critical,
        message: "audit batch sealing failed: #{ex.message}",
      )) rescue nil
    end
  end
end
