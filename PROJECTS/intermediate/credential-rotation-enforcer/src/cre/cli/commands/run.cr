# ===================
# ©AngelaMos | 2026
# run.cr
# ===================

require "../bootstrap"
require "../../engine/engine"
require "../../engine/scheduler"
require "../../engine/rotation_orchestrator"
require "../../engine/rotation_worker"
require "../../audit/batch_sealer"
require "../../audit/batch_sealer_scheduler"
require "../../policy/evaluator"
require "../../notifiers/log_notifier"
require "../../notifiers/telegram"
require "../../notifiers/telegram_subscriber"
require "../../notifiers/telegram_bot"

module CRE::Cli::Commands
  class Run
    class StartStop
      def initialize(@start_proc : Proc(Nil), @stop_proc : Proc(Nil))
      end

      def start : Nil
        @start_proc.call
      end

      def stop : Nil
        @stop_proc.call
      end
    end

    def execute(argv : Array(String), io : IO) : Int32
      _help_requested = false
      db_url = ENV["DATABASE_URL"]? || "sqlite:cre.db"
      interval = (ENV["CRE_TICK_SECONDS"]? || "60").to_i

      OptionParser.parse(argv) do |parser|
        parser.banner = "Usage: cre run [options]"
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
      log_notifier = CRE::Notifiers::LogNotifier.new(engine.bus)
      evaluator = CRE::Policy::Evaluator.new(engine.bus, persist)
      scheduler = CRE::Engine::Scheduler.new(engine.bus, interval.seconds)

      orchestrator = CRE::Engine::RotationOrchestrator.new(engine.bus, persist, envelope)
      worker = CRE::Engine::RotationWorker.new(engine.bus, orchestrator, persist)
      Bootstrap.register_rotators(worker, io)

      sealer_scheduler = if signer_obj = signer
                           sealer = CRE::Audit::BatchSealer.new(persist, signer_obj)
                           CRE::Audit::BatchSealerScheduler.new(engine.bus, sealer, Bootstrap.seal_interval)
                         end

      telegram_pieces = wire_telegram(engine.bus, persist, io)

      engine.start
      log_notifier.start
      worker.start
      evaluator.start
      scheduler.start
      sealer_scheduler.try(&.start)
      telegram_pieces.each(&.start)

      io.puts "cre running. PID #{Process.pid}, tick #{interval}s, db #{Bootstrap.redact_db_url(db_url)}"
      io.puts "rotators: #{worker.kinds.map(&.to_s).join(", ")}"
      io.puts "envelope: AES-256-GCM (KEK v#{ENV[Bootstrap::KEK_VERSION_VAR]? || "1"})"
      io.puts "audit batches: #{sealer_scheduler.nil? ? "(disabled — set #{Bootstrap::SIGNING_KEY_VAR})" : "every #{Bootstrap.seal_interval.total_seconds.to_i}s"}"
      io.puts "telegram: #{telegram_pieces.empty? ? "(disabled)" : "enabled"}"

      stop_signal = Channel(Nil).new
      Signal::INT.trap do
        io.puts "\nshutting down..."
        scheduler.stop
        evaluator.stop
        worker.stop
        sealer_scheduler.try(&.stop)
        log_notifier.stop
        telegram_pieces.each(&.stop)
        engine.stop
        persist.close
        stop_signal.send(nil) rescue nil
      end

      stop_signal.receive
      0
    rescue ex : CRE::Cli::Bootstrap::ConfigError
      io.puts "configuration error: #{ex.message}"
      78 # EX_CONFIG
    end

    private def wire_telegram(bus : CRE::Engine::EventBus, persist : CRE::Persistence::Persistence, io : IO) : Array(StartStop)
      pieces = [] of StartStop

      token = ENV["TELEGRAM_TOKEN"]?
      return pieces if token.nil? || token.empty?

      viewer_chats = parse_chat_ids(ENV["TELEGRAM_VIEWER_CHATS"]?)
      operator_chats = parse_chat_ids(ENV["TELEGRAM_OPERATOR_CHATS"]?)
      all_chats = (viewer_chats + operator_chats).uniq

      if all_chats.empty?
        io.puts "warning: TELEGRAM_TOKEN set but no TELEGRAM_VIEWER_CHATS / TELEGRAM_OPERATOR_CHATS; skipping bot"
        return pieces
      end

      telegram = CRE::Notifiers::Telegram.new(token)
      sub = CRE::Notifiers::TelegramSubscriber.new(bus, telegram, all_chats)
      bot = CRE::Notifiers::TelegramBot.new(
        bus: bus, telegram: telegram, persistence: persist,
        viewer_chats: viewer_chats, operator_chats: operator_chats,
      )

      pieces << StartStop.new(start_proc: -> { sub.start }, stop_proc: -> { sub.stop })
      pieces << StartStop.new(start_proc: -> { bot.start }, stop_proc: -> { bot.stop })
      pieces
    end

    private def parse_chat_ids(raw : String?) : Array(Int64)
      return [] of Int64 if raw.nil? || raw.empty?
      raw.split(',').map(&.strip).reject(&.empty?).map(&.to_i64)
    end
  end
end
