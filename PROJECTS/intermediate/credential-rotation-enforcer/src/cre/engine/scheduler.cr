# ===================
# ©AngelaMos | 2026
# scheduler.cr
# ===================

require "log"
require "./event_bus"
require "../events/system_events"

module CRE::Engine
  # Scheduler is a fiber that publishes SchedulerTick events at a fixed interval.
  # The PolicyEvaluator subscriber listens for these and runs evaluate_all,
  # which discovers overdue credentials and publishes RotationScheduled etc.
  #
  # The fiber owns its own lifecycle: start() spawns it; stop() flips a flag and
  # the next tick's check exits cleanly.
  class Scheduler
    Log = ::Log.for("cre.scheduler")

    @running : Bool

    def initialize(@bus : EventBus, @interval : Time::Span = 60.seconds)
      @running = false
    end

    def start : Nil
      @running = true
      spawn(name: "scheduler") do
        # Fire one tick immediately so the first evaluation doesn't wait
        # for the full interval on boot.
        @bus.publish Events::SchedulerTick.new
        while @running
          sleep @interval
          break unless @running
          begin
            @bus.publish Events::SchedulerTick.new
          rescue ex
            Log.error(exception: ex) { "scheduler tick publish failed" }
          end
        end
      end
    end

    def stop : Nil
      @running = false
    end

    def running? : Bool
      @running
    end
  end
end
