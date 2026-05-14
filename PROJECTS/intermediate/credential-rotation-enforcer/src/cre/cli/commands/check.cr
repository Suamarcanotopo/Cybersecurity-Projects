# ===================
# ©AngelaMos | 2026
# check.cr
# ===================

require "../../engine/event_bus"
require "../../persistence/sqlite/sqlite_persistence"
require "../../policy/evaluator"

module CRE::Cli::Commands
  class Check
    def execute(argv : Array(String), io : IO) : Int32
      _help_requested = false
      output_format = OutputFormat::Human
      db_path = ":memory:"

      OptionParser.parse(argv) do |parser|
        parser.banner = "Usage: cre check [options]"
        parser.on("--output=FORMAT", "human|json|ndjson") { |f| output_format = Output.parse_format(f) }
        parser.on("--db=PATH", "SQLite path (default :memory:)") { |p| db_path = p }
        parser.on("-h", "--help") { _help_requested = true; io.puts parser }
      end
      return 0 if _help_requested

      persist = CRE::Persistence::Sqlite::SqlitePersistence.new(db_path)
      persist.migrate!

      bus = CRE::Engine::EventBus.new
      ch = bus.subscribe(buffer: 256)
      bus.run

      CRE::Policy::Evaluator.new(bus, persist).evaluate_all
      sleep 0.1.seconds

      violations = drain(ch).select(&.is_a?(CRE::Events::PolicyViolation)).map(&.as(CRE::Events::PolicyViolation))
      bus.stop
      persist.close

      case output_format
      in OutputFormat::Human
        if violations.empty?
          io.puts "OK: no policy violations"
        else
          io.puts "VIOLATIONS (#{violations.size}):"
          violations.each do |v|
            io.puts "  - credential=#{v.credential_id} policy=#{v.policy_name} reason=#{v.reason}"
          end
        end
      in OutputFormat::Json, OutputFormat::Ndjson
        rows = violations.map do |v|
          {
            "credential_id" => v.credential_id.to_s,
            "policy"        => v.policy_name,
            "reason"        => v.reason,
            "occurred_at"   => v.occurred_at.to_rfc3339,
          }
        end
        Output.print(io, output_format, rows)
      end

      violations.empty? ? 0 : 1
    end

    private def drain(ch : ::Channel(CRE::Events::Event)) : Array(CRE::Events::Event)
      out = [] of CRE::Events::Event
      loop do
        select
        when ev = ch.receive
          out << ev
        else
          break
        end
      end
      out
    end
  end
end
