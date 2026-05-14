# ===================
# ©AngelaMos | 2026
# telegram_subscriber.cr
# ===================

require "log"
require "./telegram"
require "../engine/event_bus"
require "../events/credential_events"
require "../events/system_events"

module CRE::Notifiers
  # TelegramSubscriber sends emoji-prefixed messages to allowlisted chats on
  # significant events. Best-effort delivery (Drop overflow); transient
  # Telegram errors are logged and swallowed so a network blip never blocks
  # the engine.
  class TelegramSubscriber
    Log = ::Log.for("cre.telegram_subscriber")

    @ch : ::Channel(Events::Event)?
    @running : Bool

    def initialize(@bus : Engine::EventBus, @telegram : Telegram, @viewer_chats : Array(Int64), @notify_on_success : Bool = false)
      @running = false
    end

    def start : Nil
      @running = true
      ch = @bus.subscribe(buffer: 128, overflow: Engine::EventBus::Overflow::Drop)
      @ch = ch
      spawn(name: "telegram-sub") do
        while @running
          begin
            ev = ch.receive
          rescue ::Channel::ClosedError
            break
          end
          dispatch(ev)
        end
      end
    end

    def stop : Nil
      @running = false
      @ch.try(&.close)
    end

    private def dispatch(ev : Events::Event) : Nil
      msg = format(ev)
      return if msg.nil?
      @viewer_chats.each do |chat|
        @telegram.send_message(chat, msg)
      rescue ex
        Log.warn(exception: ex) { "telegram send failed for chat=#{chat}" }
      end
    end

    private def format(ev : Events::Event) : String?
      case ev
      when Events::RotationFailed
        "! Rotation FAILED for credential #{ev.credential_id} (rotation #{ev.rotation_id}): #{ev.reason}"
      when Events::DriftDetected
        "⚠ Drift detected on credential #{ev.credential_id}: hash mismatch (expected=#{ev.expected_hash[0, 12]}..., actual=#{ev.actual_hash[0, 12]}...)"
      when Events::PolicyViolation
        "⚠ Policy violation: '#{ev.policy_name}' on #{ev.credential_id} (#{ev.reason})"
      when Events::AlertRaised
        sev = case ev.severity
              in Events::Severity::Critical then "!"
              in Events::Severity::Warn     then "⚠"
              in Events::Severity::Info     then "ℹ"
              end
        "#{sev} #{ev.message}"
      when Events::RotationCompleted
        @notify_on_success ? "✓ Rotation completed for credential #{ev.credential_id}" : nil
      else
        nil
      end
    end
  end
end
