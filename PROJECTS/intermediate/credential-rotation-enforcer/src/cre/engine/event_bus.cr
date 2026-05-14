# ===================
# ©AngelaMos | 2026
# event_bus.cr
# ===================

require "log"
require "../events/event"

module CRE::Engine
  class EventBus
    Log = ::Log.for("cre.event_bus")

    enum Overflow
      Block
      Drop
    end

    record Subscription, channel : Channel(Events::Event), overflow : Overflow

    @inbox : Channel(Events::Event)
    @subs : Array(Subscription)
    @subs_mutex : Mutex
    @running : Bool

    def initialize(inbox_capacity : Int32 = 1024, @block_send_timeout : Time::Span = 5.seconds)
      @inbox = Channel(Events::Event).new(capacity: inbox_capacity)
      @subs = [] of Subscription
      @subs_mutex = Mutex.new
      @running = false
    end

    def subscribe(buffer : Int32 = 64, overflow : Overflow = Overflow::Block) : Channel(Events::Event)
      ch = Channel(Events::Event).new(capacity: buffer)
      @subs_mutex.synchronize { @subs << Subscription.new(ch, overflow) }
      ch
    end

    def publish(event : Events::Event) : Nil
      @inbox.send(event)
    end

    def run : Nil
      @running = true
      spawn(name: "event-bus") do
        while @running
          begin
            ev = @inbox.receive
          rescue Channel::ClosedError
            break
          end
          @subs_mutex.synchronize { @subs.dup }.each { |s| dispatch(s, ev) }
        end
      end
    end

    def stop : Nil
      @running = false
      @inbox.close
      @subs_mutex.synchronize do
        @subs.each(&.channel.close)
      end
    end

    # Dispatch isolates each subscriber so a slow one cannot block the bus
    # for everyone else (head-of-line blocking).
    #
    # Drop overflow uses a non-blocking select+default; rejections are
    # logged. Block overflow uses a select with a timeout; if the
    # subscriber's buffer stays full beyond the timeout, the event is
    # logged as dropped and the bus moves on rather than freezing the
    # entire pipeline. Operators tune the timeout up for slow downstreams
    # they trust (DB writes) and down for unreliable ones (Telegram).
    private def dispatch(sub : Subscription, ev : Events::Event) : Nil
      case sub.overflow
      in Overflow::Block
        select
        when sub.channel.send(ev)
          # delivered
        when timeout(@block_send_timeout)
          Log.warn { "subscriber stalled past #{@block_send_timeout.total_seconds}s; dropped: #{ev.class.name}" }
        end
      in Overflow::Drop
        select
        when sub.channel.send(ev)
          # delivered
        else
          Log.warn { "subscriber drop: #{ev.class.name}" }
        end
      end
    rescue Channel::ClosedError
      # subscriber gone; remove from list lazily on next dispatch
    end
  end
end
