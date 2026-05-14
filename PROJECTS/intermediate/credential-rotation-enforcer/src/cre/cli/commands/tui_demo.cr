# ===================
# ©AngelaMos | 2026
# tui_demo.cr
# ===================

require "../../demo/tui_demo"

module CRE::Cli::Commands
  class TuiDemo
    def execute(argv : Array(String), io : IO) : Int32
      _help_requested = false
      seconds = 8
      OptionParser.parse(argv) do |parser|
        parser.banner = "Usage: cre tui-demo [--seconds=N]"
        parser.on("--seconds=N", "duration in seconds (default 8)") { |s| seconds = s.to_i }
        parser.on("-h", "--help") { _help_requested = true; io.puts parser }
      end
      return 0 if _help_requested

      CRE::Demo::TuiDemo.run(io, seconds)
    end
  end
end
