# ===================
# ©AngelaMos | 2026
# state.cr
# ===================

require "../events/credential_events"
require "../events/system_events"

module CRE::Tui
  # State holds the rolling view of recent events for the TUI to render.
  # Updated synchronously from the event subscriber; rendering reads it.
  class State
    MAX_RECENT_EVENTS    = 20
    MAX_ACTIVE_ROTATIONS = 10

    record EventRow,
      occurred_at : Time,
      symbol : String,
      summary : String

    record RotationRow,
      credential_id : UUID,
      rotator_kind : String,
      step : String,
      progress : Int32 # 0..4

    @recent : Array(EventRow)
    @active : Hash(UUID, RotationRow)
    @completed_24h : Int32
    @started_at : Time
    @kek_version : Int32
    @creds_total : Int32
    @due_now : Int32
    @overdue : Int32

    def initialize(@kek_version : Int32 = 0)
      @recent = [] of EventRow
      @active = {} of UUID => RotationRow
      @completed_24h = 0
      @creds_total = 0
      @due_now = 0
      @overdue = 0
      @started_at = Time.utc
    end

    def update_counts(creds_total : Int32, due_now : Int32, overdue : Int32) : Nil
      @creds_total = creds_total
      @due_now = due_now
      @overdue = overdue
    end

    def apply(ev : Events::Event) : Nil
      case ev
      when Events::RotationStarted
        @active[ev.credential_id] = RotationRow.new(
          credential_id: ev.credential_id,
          rotator_kind: ev.rotator_kind,
          step: "starting",
          progress: 0,
        )
      when Events::RotationStepStarted
        if row = @active[ev.credential_id]?
          @active[ev.credential_id] = RotationRow.new(
            credential_id: row.credential_id,
            rotator_kind: row.rotator_kind,
            step: ev.step.to_s,
            progress: row.progress,
          )
        end
      when Events::RotationStepCompleted
        if row = @active[ev.credential_id]?
          @active[ev.credential_id] = RotationRow.new(
            credential_id: row.credential_id,
            rotator_kind: row.rotator_kind,
            step: ev.step.to_s,
            progress: row.progress + 1,
          )
        end
      when Events::RotationCompleted
        @active.delete(ev.credential_id)
        @completed_24h += 1
        push_event("✓", "rotation completed for #{short(ev.credential_id)}")
      when Events::RotationFailed
        @active.delete(ev.credential_id)
        push_event("!", "rotation FAILED for #{short(ev.credential_id)}: #{ev.reason}")
      when Events::PolicyViolation
        push_event("⚠", "policy '#{ev.policy_name}' violated by #{short(ev.credential_id)}")
      when Events::DriftDetected
        push_event("⚠", "drift detected on #{short(ev.credential_id)}")
      when Events::AlertRaised
        sym = case ev.severity
              in Events::Severity::Critical then "!"
              in Events::Severity::Warn     then "⚠"
              in Events::Severity::Info     then "ℹ"
              end
        push_event(sym, ev.message)
      end
    end

    getter recent : Array(EventRow)
    getter active : Hash(UUID, RotationRow)
    getter completed_24h : Int32
    getter started_at : Time
    getter kek_version : Int32
    getter creds_total : Int32
    getter due_now : Int32
    getter overdue : Int32

    def uptime : Time::Span
      Time.utc - @started_at
    end

    private def push_event(symbol : String, summary : String) : Nil
      @recent << EventRow.new(occurred_at: Time.utc, symbol: symbol, summary: summary)
      @recent.shift if @recent.size > MAX_RECENT_EVENTS
    end

    private def short(uuid : UUID) : String
      uuid.to_s[0, 8]
    end
  end
end
