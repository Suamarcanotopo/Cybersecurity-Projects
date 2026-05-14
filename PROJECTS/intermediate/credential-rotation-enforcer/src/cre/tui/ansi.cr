# ===================
# ©AngelaMos | 2026
# ansi.cr
# ===================

module CRE::Tui
  # Minimal ANSI escape helpers. We hand-roll instead of depending on a TUI
  # framework so the rendering is small, predictable, and easy to test by
  # capturing IO writes.
  module Ansi
    ESC = "\e["

    CLEAR_SCREEN = "#{ESC}2J"
    CLEAR_LINE   = "#{ESC}2K"
    HIDE_CURSOR  = "#{ESC}?25l"
    SHOW_CURSOR  = "#{ESC}?25h"
    HOME         = "#{ESC}H"
    RESET        = "#{ESC}0m"

    BOLD = "#{ESC}1m"
    DIM  = "#{ESC}2m"

    FG_RED    = "#{ESC}31m"
    FG_GREEN  = "#{ESC}32m"
    FG_YELLOW = "#{ESC}33m"
    FG_BLUE   = "#{ESC}34m"
    FG_CYAN   = "#{ESC}36m"
    FG_WHITE  = "#{ESC}37m"
    FG_GRAY   = "#{ESC}90m"

    def self.move(row : Int, col : Int) : String
      "#{ESC}#{row};#{col}H"
    end

    def self.colorize(text : String, color : String) : String
      "#{color}#{text}#{RESET}"
    end

    def self.green(text : String) : String
      colorize(text, FG_GREEN)
    end

    def self.red(text : String) : String
      colorize(text, FG_RED)
    end

    def self.yellow(text : String) : String
      colorize(text, FG_YELLOW)
    end

    def self.cyan(text : String) : String
      colorize(text, FG_CYAN)
    end

    def self.gray(text : String) : String
      colorize(text, FG_GRAY)
    end

    def self.bold(text : String) : String
      colorize(text, BOLD)
    end

    def self.dim(text : String) : String
      colorize(text, DIM)
    end

    # Strip ANSI escape sequences (useful for testing rendered output).
    def self.strip(text : String) : String
      text.gsub(/\e\[[0-9;?]*[a-zA-Z]/, "")
    end
  end
end
