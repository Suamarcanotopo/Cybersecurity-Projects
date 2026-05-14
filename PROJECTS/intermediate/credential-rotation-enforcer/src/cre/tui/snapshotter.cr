# ===================
# ©AngelaMos | 2026
# snapshotter.cr
# ===================

require "log"
require "./state"
require "../persistence/persistence"
require "../policy/policy"

module CRE::Tui
  # Snapshotter polls the persistence layer at a low frequency and updates
  # State#creds_total / due_now / overdue. The TUI render path reads the
  # cached snapshot, never the database — so a slow query can't stall
  # frame paint.
  class Snapshotter
    Log = ::Log.for("cre.tui.snapshotter")

    @running : Bool

    def initialize(
      @state : State,
      @persistence : Persistence::Persistence,
      @policies : Array(Policy::Policy) = Policy.registry,
      @interval : Time::Span = 5.seconds,
    )
      @running = false
    end

    def start : Nil
      @running = true
      spawn(name: "tui-snapshotter") do
        refresh
        while @running
          sleep @interval
          break unless @running
          refresh
        end
      end
    end

    def stop : Nil
      @running = false
    end

    def refresh : Nil
      now = Time.utc
      creds = @persistence.credentials.all
      total = creds.size

      due_now = 0
      overdue = 0
      creds.each do |c|
        matching = @policies.select(&.matches?(c))
        next if matching.empty?
        policy = matching.last
        if policy.overdue?(c, now)
          overdue += 1
        elsif policy.in_warning_window?(c, now)
          due_now += 1
        end
      end

      @state.update_counts(total, due_now, overdue)
    rescue ex
      Log.warn(exception: ex) { "tui snapshot refresh failed" }
    end
  end
end
