# ===================
# ©AngelaMos | 2026
# tier_1.cr
# ===================

require "../engine/event_bus"
require "../engine/rotation_orchestrator"
require "../engine/subscribers/audit_subscriber"
require "../persistence/sqlite/sqlite_persistence"
require "../rotators/env_file"
require "../audit/audit_log"
require "../tui/ansi"

module CRE::Demo
  module Tier1
    def self.run(io : IO) : Int32
      tmp_env = File.tempname("cre-demo-", ".env")
      File.write(tmp_env, "API_KEY=oldvalue-aaa\nOTHER=keep\n")

      io.puts CRE::Tui::Ansi.cyan("Credential Rotation Enforcer - Tier 1 demo")
      io.puts "  (in-memory SQLite + ephemeral .env file rotator, zero external deps)"
      io.puts ""

      persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
      persist.migrate!
      log = CRE::Audit::AuditLog.new(persist, Bytes.new(32, 0_u8), 1, 1024)

      cred_id = UUID.random
      cred = CRE::Domain::Credential.new(
        id: cred_id,
        external_id: "demo-#{tmp_env}",
        kind: CRE::Domain::CredentialKind::EnvFile,
        name: "API_KEY",
        tags: {
          "path"  => tmp_env,
          "key"   => "API_KEY",
          "bytes" => "16",
        } of String => String,
        updated_at: Time.utc - 60.days,
      )
      persist.credentials.insert(cred)

      io.puts CRE::Tui::Ansi.bold("Step 1 - Inventory:")
      io.puts "  - #{cred.kind} '#{cred.name}' (id=#{short(cred.id)})"
      io.puts "    last updated #{cred.updated_at.to_rfc3339} (60 days ago - overdue)"
      io.puts ""

      io.puts CRE::Tui::Ansi.bold("Step 2 - File contents BEFORE:")
      File.read(tmp_env).each_line { |line| io.puts "  #{line}" }
      io.puts ""

      io.puts CRE::Tui::Ansi.bold("Step 3 - Rotating (4-step contract):")
      bus = CRE::Engine::EventBus.new
      ch = bus.subscribe(buffer: 256)
      audit_sub = CRE::Engine::Subscribers::AuditSubscriber.new(bus, log)
      audit_sub.start
      bus.run

      rotator = CRE::Rotators::EnvFileRotator.new
      orchestrator = CRE::Engine::RotationOrchestrator.new(bus, persist)
      state = orchestrator.run(cred, rotator)

      sleep 0.15.seconds
      drain_steps(ch, io)

      audit_sub.stop
      bus.stop

      io.puts ""
      io.puts CRE::Tui::Ansi.bold("Step 4 - File contents AFTER:")
      File.read(tmp_env).each_line { |line| io.puts "  #{line}" }
      io.puts ""

      io.puts CRE::Tui::Ansi.bold("Step 5 - Audit chain verification:")
      ok = log.verify_chain
      latest_seq = persist.audit.latest_seq
      if ok
        io.puts "  #{CRE::Tui::Ansi.green("✓")} #{latest_seq} audit events, hash chain valid"
      else
        io.puts "  #{CRE::Tui::Ansi.red("✗")} audit chain BROKEN"
      end

      persist.close
      File.delete(tmp_env) if File.exists?(tmp_env)

      io.puts ""
      io.puts CRE::Tui::Ansi.dim("Demo complete. State #{state}. Try 'cre run --db=sqlite:cre.db' for the daemon.")
      state == CRE::Persistence::RotationState::Completed ? 0 : 1
    end

    private def self.drain_steps(ch : ::Channel(CRE::Events::Event), io : IO) : Nil
      loop do
        select
        when ev = ch.receive
          narrate(ev, io)
        else
          break
        end
      end
    end

    private def self.narrate(ev : CRE::Events::Event, io : IO) : Nil
      case ev
      when CRE::Events::RotationStepStarted
        io.puts "  - step started: #{ev.step}"
      when CRE::Events::RotationStepCompleted
        io.puts "  #{CRE::Tui::Ansi.green("✓")} step completed: #{ev.step}"
      when CRE::Events::RotationStepFailed
        io.puts "  #{CRE::Tui::Ansi.red("✗")} step failed: #{ev.step} (#{ev.error})"
      when CRE::Events::RotationCompleted
        io.puts "  #{CRE::Tui::Ansi.green("✓")} rotation completed"
      when CRE::Events::RotationFailed
        io.puts "  #{CRE::Tui::Ansi.red("✗")} rotation failed: #{ev.reason}"
      end
    end

    private def self.short(uuid : UUID) : String
      uuid.to_s[0, 8]
    end
  end
end
