# ===================
# ©AngelaMos | 2026
# tui.cr
# ===================

require "./ansi"
require "./state"
require "./renderer"
require "./snapshotter"
require "../engine/event_bus"

module CRE::Tui
  # Tui glues State + Renderer to the event bus. A single fiber consumes events
  # (Drop overflow - stale UI is acceptable) and triggers a repaint at most
  # every refresh_interval to coalesce bursts.
  class Tui
    @running : Bool
    @ch : ::Channel(Events::Event)?
    @last_render : Time

    def initialize(
      @bus : Engine::EventBus,
      @state : State = State.new,
      @io : IO = STDOUT,
      @refresh_interval : Time::Span = 200.milliseconds,
      @use_color : Bool = true,
    )
      @running = false
      @last_render = Time::UNIX_EPOCH
    end

    def start : Nil
      @running = true
      ch = @bus.subscribe(buffer: 64, overflow: Engine::EventBus::Overflow::Drop)
      @ch = ch
      enter_alt_screen if @io == STDOUT

      spawn(name: "tui-events") do
        while @running
          begin
            ev = ch.receive
          rescue ::Channel::ClosedError
            break
          end
          @state.apply(ev)
          maybe_render
        end
      end

      spawn(name: "tui-tick") do
        while @running
          sleep @refresh_interval
          maybe_render
        end
      end

      maybe_render(force: true)
    end

    def stop : Nil
      @running = false
      @ch.try(&.close)
      leave_alt_screen if @io == STDOUT
    end

    def state : State
      @state
    end

    def force_render : Nil
      Renderer.new(@state, @io, @use_color).render
      @last_render = Time.utc
    end

    private def maybe_render(force : Bool = false) : Nil
      now = Time.utc
      return if !force && (now - @last_render) < @refresh_interval
      Renderer.new(@state, @io, @use_color).render
      @last_render = now
    end

    private def enter_alt_screen : Nil
      @io << "\e[?1049h"
      @io << Ansi::HIDE_CURSOR
      @io << Ansi::CLEAR_SCREEN
      @io.flush
    end

    private def leave_alt_screen : Nil
      @io << Ansi::SHOW_CURSOR
      @io << "\e[?1049l"
      @io.flush
    end
  end
end
