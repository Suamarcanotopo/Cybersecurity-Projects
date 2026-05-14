# ===================
# ©AngelaMos | 2026
# rotate.cr
# ===================

require "../bootstrap"
require "../../engine/event_bus"
require "../../engine/rotation_orchestrator"
require "../../engine/rotation_worker"

module CRE::Cli::Commands
  class Rotate
    def execute(argv : Array(String), io : IO) : Int32
      _help_requested = false
      db_url = ENV["DATABASE_URL"]? || "sqlite:cre.db"
      cred_id_str = nil

      OptionParser.parse(argv) do |parser|
        parser.banner = "Usage: cre rotate <credential-id> [options]"
        parser.on("--db=URL", "database URL (sqlite:path or postgres://...)") { |u| db_url = u }
        parser.on("-h", "--help") { _help_requested = true; io.puts parser }
        parser.unknown_args { |args| cred_id_str = args.first? }
      end
      return 0 if _help_requested

      if cred_id_str.nil?
        io.puts "usage: cre rotate <credential-id>"
        return 64
      end

      cred_id = UUID.new(cred_id_str.not_nil!) rescue nil
      if cred_id.nil?
        io.puts "invalid credential id"
        return 64
      end

      envelope = CRE::Cli::Bootstrap.envelope

      persist = CRE::Cli::Bootstrap.build_persistence(db_url)
      persist.migrate!

      cred = persist.credentials.find(cred_id)
      if cred.nil?
        io.puts "credential not found: #{cred_id}"
        persist.close
        return 1
      end

      bus = CRE::Engine::EventBus.new
      bus.run
      orchestrator = CRE::Engine::RotationOrchestrator.new(bus, persist, envelope)
      worker = CRE::Engine::RotationWorker.new(bus, orchestrator, persist)
      CRE::Cli::Bootstrap.register_rotators(worker, io)

      rotator = worker.rotator_for_kind(cred.kind)
      if rotator.nil?
        io.puts "no rotator registered for #{cred.kind} (set the matching env vars; see README)"
        bus.stop
        persist.close
        return 1
      end

      io.puts "Rotating #{cred.name} (#{cred.id}) via #{rotator.kind}..."
      state = orchestrator.run(cred, rotator)
      sleep 0.1.seconds
      bus.stop
      persist.close

      case state
      when CRE::Persistence::RotationState::Completed    then io.puts "✓ rotation completed"; 0
      when CRE::Persistence::RotationState::Failed       then io.puts "✗ rotation failed"; 1
      when CRE::Persistence::RotationState::Inconsistent then io.puts "✗ rotation INCONSISTENT — manual intervention required"; 2
      else                                                    io.puts "rotation ended in unexpected state #{state}"; 2
      end
    rescue ex : CRE::Cli::Bootstrap::ConfigError
      io.puts "configuration error: #{ex.message}"
      78
    end
  end
end
