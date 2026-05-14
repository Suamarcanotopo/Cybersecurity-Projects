# ===================
# ©AngelaMos | 2026
# cli.cr
# ===================

require "option_parser"
require "../version"
require "./output"
require "./commands"

module CRE::Cli
  USAGE = <<-USAGE
  cre - Credential Rotation Enforcer

  Usage: cre <subcommand> [options]

  Subcommands:
    run                          headless daemon (production / systemd)
    watch                        engine + live TUI in same process
    check                        evaluate policies once, exit non-zero on violations
    rotate <credential-id>       manually rotate a single credential
    policy list                  list compiled-in policies
    policy show <name>           inspect one policy
    export --framework=<name>    generate signed compliance evidence bundle
    audit verify                 verify hash chain + HMAC ratchet + Merkle batches
    verify-bundle <zip>          verify a compliance evidence ZIP offline
    demo                         tier-1 zero-deps demo (SQLite + .env rotator)
    tui-demo                     8-second TUI preview with synthetic events
    version                      print version
    help                         this message

  Common options:
    --output=human|json|ndjson   output format (default: human)
    --config=PATH                config file (default: $CRE_CONFIG or ./config.cr)
  USAGE

  def self.dispatch(argv : Array(String), io : IO = STDOUT) : Int32
    if argv.empty? || %w[--help -h help].includes?(argv.first)
      io.puts USAGE
      return argv.empty? ? 64 : 0 # 64 = EX_USAGE
    end

    subcommand = argv.shift
    case subcommand
    when "version"
      io.puts CRE::VERSION
      0
    when "run"           then Commands::Run.new.execute(argv, io)
    when "watch"         then Commands::Watch.new.execute(argv, io)
    when "check"         then Commands::Check.new.execute(argv, io)
    when "rotate"        then Commands::Rotate.new.execute(argv, io)
    when "policy"        then Commands::Policy.new.execute(argv, io)
    when "export"        then Commands::Export.new.execute(argv, io)
    when "audit"         then Commands::Audit.new.execute(argv, io)
    when "verify-bundle" then Commands::VerifyBundle.new.execute(argv, io)
    when "demo"          then Commands::Demo.new.execute(argv, io)
    when "tui-demo"      then Commands::TuiDemo.new.execute(argv, io)
    else
      io.puts "unknown subcommand: #{subcommand}"
      io.puts USAGE
      64
    end
  rescue ex : OptionParser::InvalidOption | OptionParser::MissingOption
    io.puts "error: #{ex.message}"
    64
  rescue ex
    io.puts "error: #{ex.message}"
    1
  end
end
