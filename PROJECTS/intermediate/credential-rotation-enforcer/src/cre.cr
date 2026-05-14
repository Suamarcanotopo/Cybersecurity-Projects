# ===================
# ©AngelaMos | 2026
# cre.cr
# ===================

require "./cre/version"
require "./cre/cli/cli"

module CRE
  def self.main(argv : Array(String)) : Int32
    Cli.dispatch(argv)
  end
end

if PROGRAM_NAME.includes?("cre")
  exit CRE.main(ARGV)
end
