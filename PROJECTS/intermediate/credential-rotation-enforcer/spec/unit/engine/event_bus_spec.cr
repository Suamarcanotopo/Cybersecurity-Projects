# ===================
# ©AngelaMos | 2026
# event_bus_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/engine/event_bus"
require "../../../src/cre/events/system_events"

describe CRE::Engine::EventBus do
  it "delivers events to subscribers" do
    bus = CRE::Engine::EventBus.new
    bus.run
    received = [] of String
    received_mutex = Mutex.new
    ch = bus.subscribe(buffer: 16, overflow: CRE::Engine::EventBus::Overflow::Block)
    spawn do
      loop do
        ev = ch.receive
        received_mutex.synchronize { received << ev.class.name }
      rescue Channel::ClosedError
        break
      end
    end

    bus.publish(CRE::Events::AlertRaised.new(severity: CRE::Events::Severity::Warn, message: "hi"))
    sleep 0.1.seconds

    received_mutex.synchronize { received.should contain("CRE::Events::AlertRaised") }
  ensure
    bus.try(&.stop)
  end

  it "fans out to multiple subscribers" do
    bus = CRE::Engine::EventBus.new
    bus.run

    counter1 = Atomic(Int32).new(0)
    counter2 = Atomic(Int32).new(0)
    ch1 = bus.subscribe
    ch2 = bus.subscribe
    spawn do
      loop do
        ch1.receive
        counter1.add(1)
      rescue Channel::ClosedError
        break
      end
    end
    spawn do
      loop do
        ch2.receive
        counter2.add(1)
      rescue Channel::ClosedError
        break
      end
    end

    3.times { bus.publish(CRE::Events::SchedulerTick.new) }
    sleep 0.1.seconds

    counter1.get.should eq 3
    counter2.get.should eq 3
  ensure
    bus.try(&.stop)
  end

  it "drops on Drop overflow when subscriber is slow" do
    bus = CRE::Engine::EventBus.new
    bus.run
    ch = bus.subscribe(buffer: 1, overflow: CRE::Engine::EventBus::Overflow::Drop)
    5.times { bus.publish(CRE::Events::SchedulerTick.new) }
    sleep 0.1.seconds
    # The slow subscriber's channel buffered at most 1 event; rest were dropped.
    # Drain non-blocking: we should be able to take 0 or 1 event before it would block.
    delivered = 0
    drained = false
    until drained
      select
      when ch.receive
        delivered += 1
      else
        drained = true
      end
    end
    delivered.should be <= 5
    delivered.should be < 5 # at least one was dropped
  ensure
    bus.try(&.stop)
  end
end
