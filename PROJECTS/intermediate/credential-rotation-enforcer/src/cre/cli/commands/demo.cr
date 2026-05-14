# ===================
# ©AngelaMos | 2026
# demo.cr
# ===================

require "../../demo/tier_1"

module CRE::Cli::Commands
  class Demo
    def execute(argv : Array(String), io : IO) : Int32
      _help_requested = false
      OptionParser.parse(argv) do |parser|
        parser.banner = "Usage: cre demo (tier-1, no external deps)"
        parser.on("-h", "--help") { _help_requested = true; io.puts parser }
      end
      return 0 if _help_requested

      CRE::Demo::Tier1.run(io)
    end
  end
end
