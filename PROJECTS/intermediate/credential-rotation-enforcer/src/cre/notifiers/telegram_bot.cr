# ===================
# ©AngelaMos | 2026
# telegram_bot.cr
# ===================

require "log"
require "./telegram"
require "../engine/event_bus"
require "../persistence/persistence"

module CRE::Notifiers
  # TelegramBot does long-polling getUpdates and dispatches commands to
  # operator handlers. Two ACL tiers:
  #   - viewer  : read-only commands (/status, /queue, /history, /alerts, /help)
  #   - operator: viewer + mutating commands (/rotate, /snooze)
  #
  # Authorization is by chat_id; not strictly authentication but adequate for a
  # single-tenant deployment where the bot token + chat IDs live in env vars.
  class TelegramBot
    Log = ::Log.for("cre.telegram_bot")

    @running : Bool
    @last_offset : Int64

    def initialize(
      @bus : Engine::EventBus,
      @telegram : Telegram,
      @persistence : Persistence::Persistence,
      @viewer_chats : Array(Int64),
      @operator_chats : Array(Int64),
    )
      @running = false
      @last_offset = 0_i64
    end

    def start : Nil
      @running = true
      spawn(name: "telegram-bot") do
        while @running
          begin
            poll_once
          rescue ex
            Log.error(exception: ex) { "telegram bot poll failed" }
            sleep 1.second
          end
        end
      end
    end

    def stop : Nil
      @running = false
    end

    def authorized_viewer?(chat_id : Int64) : Bool
      @viewer_chats.includes?(chat_id) || @operator_chats.includes?(chat_id)
    end

    def authorized_operator?(chat_id : Int64) : Bool
      @operator_chats.includes?(chat_id)
    end

    def handle_command(chat_id : Int64, text : String) : String
      return "unauthorized" unless authorized_viewer?(chat_id)
      cmd, _, rest = text.strip.lstrip('/').partition(' ')
      case cmd
      when "status"   then status_message
      when "queue"    then queue_message
      when "alerts"   then alerts_message
      when "help", "" then help_message
      when "rotate"   then handle_rotate(chat_id, rest)
      when "history"  then history_message(rest)
      else
        "unknown command: /#{cmd} (try /help)"
      end
    end

    def poll_once : Nil
      updates = @telegram.get_updates(offset: @last_offset == 0 ? nil : @last_offset, timeout: 5)
      updates.each do |u|
        @last_offset = u.update_id + 1
        chat_id = u.chat_id
        text = u.text
        next if chat_id.nil? || text.nil? || !text.starts_with?('/')
        reply = handle_command(chat_id, text)
        @telegram.send_message(chat_id, reply) rescue nil
      end
    end

    private def status_message : String
      total = @persistence.credentials.all.size
      in_flight = @persistence.rotations.in_flight.size
      "● live\nCredentials: #{total}\nIn-flight rotations: #{in_flight}"
    end

    private def queue_message : String
      in_flight = @persistence.rotations.in_flight
      return "queue empty" if in_flight.empty?
      lines = in_flight.first(10).map { |r| "- #{r.rotator_kind} #{r.credential_id} [#{r.state}]" }
      "Active queue (#{in_flight.size}):\n#{lines.join('\n')}"
    end

    private def alerts_message : String
      "Alerts inspection is exposed via the audit log; use 'cre audit verify --since=...' from the CLI."
    end

    private def help_message : String
      <<-MD
      Available commands:
        /status            - quick health summary
        /queue             - active rotations
        /history <id>      - last events for a credential
        /alerts            - critical alerts pointer
        /rotate <id>       - force rotation (operator)
      MD
    end

    private def handle_rotate(chat_id : Int64, rest : String) : String
      return "operator-only command" unless authorized_operator?(chat_id)
      id_str = rest.strip
      return "usage: /rotate <credential-id>" if id_str.empty?
      uuid = UUID.new(id_str) rescue nil
      return "invalid credential id" if uuid.nil?
      @bus.publish Events::RotationScheduled.new(uuid, "manual")
      "rotation scheduled for #{uuid}"
    end

    private def history_message(rest : String) : String
      id_str = rest.strip
      return "usage: /history <credential-id>" if id_str.empty?
      uuid = UUID.new(id_str) rescue nil
      return "invalid credential id" if uuid.nil?
      cred = @persistence.credentials.find(uuid)
      return "credential not found" if cred.nil?
      latest = @persistence.audit.latest_seq
      entries = latest > 10 ? @persistence.audit.range(latest - 9, latest) : @persistence.audit.range(1_i64, latest)
      filtered = entries.select { |e| e.target_id == uuid }
      return "no audit entries for #{uuid}" if filtered.empty?
      lines = filtered.last(10).map { |e| "- #{e.occurred_at.to_rfc3339}: #{e.event_type}" }
      "Last events for #{cred.name}:\n#{lines.join('\n')}"
    end
  end
end
