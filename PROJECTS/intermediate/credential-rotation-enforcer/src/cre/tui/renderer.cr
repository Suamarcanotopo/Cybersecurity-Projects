# ===================
# ©AngelaMos | 2026
# renderer.cr
# ===================

require "./ansi"
require "./state"

module CRE::Tui
  # Renderer paints the four-panel TUI to a target IO. Decoupled from terminal
  # ownership so it can render to STDOUT in production or to IO::Memory in
  # tests for assertion.
  class Renderer
    HEADER     = "Credential Rotation Enforcer"
    PANEL_HR   = "─"
    PANEL_BL   = "└"
    PANEL_BR   = "┘"
    PANEL_TL   = "┌"
    PANEL_TR   = "┐"
    PANEL_VL   = "│"
    PANEL_LMID = "├"
    PANEL_RMID = "┤"
    WIDTH      = 64

    def initialize(@state : State, @io : IO = STDOUT, @use_color : Bool = true)
    end

    def render : Nil
      @io << Ansi::HOME
      render_header
      render_status
      render_active
      render_recent
      render_footer
      @io.flush
    end

    private def render_header : Nil
      title = "#{HEADER} - PID #{Process.pid} | Uptime #{format_span(@state.uptime)}"
      line = pad_centered(title, WIDTH - 2)
      @io << PANEL_TL << PANEL_HR * (WIDTH - 2) << PANEL_TR << '\n'
      @io << PANEL_VL << colorize(line, Ansi::FG_CYAN) << PANEL_VL << '\n'
      @io << PANEL_LMID << PANEL_HR * (WIDTH - 2) << PANEL_RMID << '\n'
    end

    private def render_status : Nil
      header = " STATUS    CREDS    DUE-NOW    OVERDUE    ROTATED-24h    KEK"
      values = " #{Ansi.green("● live")}   #{cell(@state.creds_total, 8)}#{cell(@state.due_now, 11)}#{cell(@state.overdue, 11)}#{cell(@state.completed_24h, 15)}v#{@state.kek_version}"
      @io << PANEL_VL << pad(header, WIDTH - 2) << PANEL_VL << '\n'
      @io << PANEL_VL << pad(values, WIDTH - 2) << PANEL_VL << '\n'
      @io << PANEL_LMID << " Active Rotations " << PANEL_HR * (WIDTH - 21) << PANEL_RMID << '\n'
    end

    private def cell(n : Int, width : Int) : String
      n.to_s.ljust(width)
    end

    private def render_active : Nil
      if @state.active.empty?
        @io << PANEL_VL << pad("  (no active rotations)", WIDTH - 2) << PANEL_VL << '\n'
      else
        @state.active.values.first(State::MAX_ACTIVE_ROTATIONS).each do |row|
          progress = "▰" * row.progress + "▱" * (4 - row.progress)
          line = "  [▶] #{row.rotator_kind.ljust(20)} #{progress}  step #{row.progress}/4: #{row.step}"
          @io << PANEL_VL << pad(line, WIDTH - 2) << PANEL_VL << '\n'
        end
      end
      @io << PANEL_LMID << " Recent Events " << PANEL_HR * (WIDTH - 18) << PANEL_RMID << '\n'
    end

    private def render_recent : Nil
      if @state.recent.empty?
        @io << PANEL_VL << pad("  (no events yet)", WIDTH - 2) << PANEL_VL << '\n'
      else
        @state.recent.last(8).each do |row|
          ts = row.occurred_at.to_s("%H:%M:%S")
          line = "  #{ts}  #{row.symbol}  #{row.summary}"
          @io << PANEL_VL << pad(line, WIDTH - 2) << PANEL_VL << '\n'
        end
      end
    end

    private def render_footer : Nil
      @io << PANEL_BL << PANEL_HR * (WIDTH - 2) << PANEL_BR << '\n'
      @io << Ansi.dim(" Press Ctrl+C to exit") << '\n'
    end

    private def colorize(text : String, color : String) : String
      @use_color ? Ansi.colorize(text, color) : text
    end

    private def pad(text : String, width : Int) : String
      visible = Ansi.strip(text)
      return text[0, width + (text.size - visible.size)] if visible.size >= width
      text + " " * (width - visible.size)
    end

    private def pad_centered(text : String, width : Int) : String
      visible_size = Ansi.strip(text).size
      return text[0, width] if visible_size >= width
      pad = (width - visible_size) // 2
      " " * pad + text + " " * (width - pad - visible_size)
    end

    private def format_span(span : Time::Span) : String
      total = span.total_seconds.to_i
      hours = total // 3600
      mins = (total % 3600) // 60
      "#{hours}h #{mins}m"
    end
  end
end
