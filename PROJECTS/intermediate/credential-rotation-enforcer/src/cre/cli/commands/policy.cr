# ===================
# ©AngelaMos | 2026
# policy.cr
# ===================

require "../../policy/policy"

module CRE::Cli::Commands
  class Policy
    def execute(argv : Array(String), io : IO) : Int32
      sub = argv.shift?
      case sub
      when "list" then list(argv, io)
      when "show" then show(argv, io)
      when nil, "--help", "-h"
        io.puts "Usage: cre policy <list|show <name>>"
        0
      else
        io.puts "unknown policy subcommand: #{sub}"
        64
      end
    end

    private def list(argv : Array(String), io : IO) : Int32
      output_format = OutputFormat::Human
      OptionParser.parse(argv) do |parser|
        parser.on("--output=FORMAT", "human|json") { |f| output_format = Output.parse_format(f) }
      end

      policies = CRE::Policy.registry
      case output_format
      in OutputFormat::Human
        if policies.empty?
          io.puts "(no policies compiled in)"
        else
          io.puts "Compiled policies:"
          policies.each { |p| io.puts "  - #{p.name} (max_age=#{p.max_age}, enforce=#{p.enforce_action.to_s.downcase})" }
        end
      in OutputFormat::Json, OutputFormat::Ndjson
        rows = policies.map do |p|
          {
            "name"    => p.name,
            "max_age" => p.max_age.to_s,
            "enforce" => p.enforce_action.to_s.downcase,
            "warn_at" => p.warn_at.try(&.to_s),
          }
        end
        Output.print(io, output_format, rows)
      end
      0
    end

    private def show(argv : Array(String), io : IO) : Int32
      name = argv.shift?
      if name.nil?
        io.puts "usage: cre policy show <name>"
        return 64
      end
      policy = CRE::Policy.registry.find { |p| p.name == name }
      if policy.nil?
        io.puts "policy not found: #{name}"
        return 1
      end
      io.puts "name:    #{policy.name}"
      io.puts "desc:    #{policy.description || "(none)"}"
      io.puts "max_age: #{policy.max_age}"
      io.puts "warn_at: #{policy.warn_at || "(none)"}"
      io.puts "enforce: #{policy.enforce_action.to_s.downcase}"
      io.puts "channels: #{policy.notify_channels.map(&.to_s.downcase).join(", ")}"
      io.puts "triggers:"
      policy.triggers.each { |k, v| io.puts "  #{k.to_s.downcase}: #{v.to_s.downcase}" }
      0
    end
  end
end
