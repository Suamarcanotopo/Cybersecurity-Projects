# ===================
# ©AngelaMos | 2026
# scheduler_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/engine/scheduler"
require "../../../src/cre/engine/event_bus"

private def drain(ch : ::Channel(CRE::Events::Event)) : Array(CRE::Events::Event)
  out = [] of CRE::Events::Event
  loop do
    select
    when ev = ch.receive
      out << ev
    else
      break
    end
  end
  out
end

describe CRE::Engine::Scheduler do
  it "publishes a tick immediately on start" do
    bus = CRE::Engine::EventBus.new
    ch = bus.subscribe
    bus.run

    scheduler = CRE::Engine::Scheduler.new(bus, interval: 5.seconds)
    scheduler.start
    sleep 0.1.seconds
    scheduler.stop

    ticks = drain(ch).count(&.is_a?(CRE::Events::SchedulerTick))
    ticks.should be >= 1
  ensure
    bus.try(&.stop)
  end

  it "publishes ticks at the configured interval" do
    bus = CRE::Engine::EventBus.new
    ch = bus.subscribe(buffer: 64)
    bus.run

    scheduler = CRE::Engine::Scheduler.new(bus, interval: 0.05.seconds)
    scheduler.start
    sleep 0.18.seconds
    scheduler.stop
    sleep 0.05.seconds # let final tick land

    ticks = drain(ch).count(&.is_a?(CRE::Events::SchedulerTick))
    # Initial + ~3 interval ticks = 3-5 expected; allow some scheduling variance
    ticks.should be >= 2
    ticks.should be <= 6
  ensure
    bus.try(&.stop)
  end

  it "stop halts publication" do
    bus = CRE::Engine::EventBus.new
    ch = bus.subscribe
    bus.run

    scheduler = CRE::Engine::Scheduler.new(bus, interval: 0.05.seconds)
    scheduler.start
    sleep 0.06.seconds
    scheduler.stop
    drain(ch) # drain whatever was already published
    sleep 0.2.seconds

    later = drain(ch).count(&.is_a?(CRE::Events::SchedulerTick))
    later.should be <= 1 # at most one in-flight tick from the last sleep cycle
  ensure
    bus.try(&.stop)
  end
end
