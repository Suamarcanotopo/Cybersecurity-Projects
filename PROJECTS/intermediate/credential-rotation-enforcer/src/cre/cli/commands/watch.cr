# ===================
# ©AngelaMos | 2026
# watch.cr
# ===================

require "../bootstrap"
require "../../engine/engine"
require "../../engine/scheduler"
require "../../engine/rotation_orchestrator"
require "../../engine/rotation_worker"
require "../../audit/batch_sealer"
require "../../audit/batch_sealer_scheduler"
require "../../policy/evaluator"
require "../../tui/tui"

module CRE::Cli::Commands
  class Watch
    def execute(argv : Array(String), io : IO) : Int32
      _help_requested = false
      db_url = ENV["DATABASE_URL"]? || "sqlite:cre.db"
      interval = (ENV["CRE_TICK_SECONDS"]? || "60").to_i

      OptionParser.parse(argv) do |parser|
        parser.banner = "Usage: cre watch [options]"
        parser.on("--db=URL", "database URL (sqlite:path or postgres://...)") { |u| db_url = u }
        parser.on("--interval=SECONDS", "scheduler tick interval") { |i| interval = i.to_i }
        parser.on("-h", "--help") { _help_requested = true; io.puts parser }
      end
      return 0 if _help_requested

      hmac_key = Bootstrap.require_hmac_key
      envelope = Bootstrap.require_envelope
      signer = Bootstrap.signer

      persist = Bootstrap.build_persistence(db_url)
      persist.migrate!

      engine = CRE::Engine::Engine.new(persist, hmac_key)
      evaluator = CRE::Policy::Evaluator.new(engine.bus, persist)
      scheduler = CRE::Engine::Scheduler.new(engine.bus, interval.seconds)
      orchestrator = CRE::Engine::RotationOrchestrator.new(engine.bus, persist, envelope)
      worker = CRE::Engine::RotationWorker.new(engine.bus, orchestrator, persist)
      Bootstrap.register_rotators(worker, io)

      sealer_scheduler = if signer_obj = signer
                           sealer = CRE::Audit::BatchSealer.new(persist, signer_obj)
                           CRE::Audit::BatchSealerScheduler.new(engine.bus, sealer, Bootstrap.seal_interval)
                         end

      kek_version = (ENV[Bootstrap::KEK_VERSION_VAR]? || "1").to_i
      tui_state = CRE::Tui::State.new(kek_version: kek_version)
      tui_snapshotter = CRE::Tui::Snapshotter.new(tui_state, persist)
      tui = CRE::Tui::Tui.new(engine.bus, tui_state)

      engine.start
      worker.start
      evaluator.start
      scheduler.start
      sealer_scheduler.try(&.start)
      tui_snapshotter.start
      tui.start

      Signal::INT.trap do
        tui.stop
        tui_snapshotter.stop
        scheduler.stop
        evaluator.stop
        worker.stop
        sealer_scheduler.try(&.stop)
        engine.stop
        persist.close
        exit 0
      end

      sleep
      0
    rescue ex : CRE::Cli::Bootstrap::ConfigError
      io.puts "configuration error: #{ex.message}"
      78
    end
  end
end
