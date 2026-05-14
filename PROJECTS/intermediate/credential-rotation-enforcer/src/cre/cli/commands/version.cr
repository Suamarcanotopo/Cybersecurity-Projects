# ===================
# ©AngelaMos | 2026
# version.cr
# ===================

require "../../version"

module CRE::Cli::Commands
  module Version
    def self.print(io : IO) : Nil
      io.puts "cre v#{CRE::VERSION}"
    end
  end
end
