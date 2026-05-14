# ===================
# ©AngelaMos | 2026
# telegram_bot_spec.cr
# ===================

require "../../spec_helper"
require "webmock"
require "../../../src/cre/notifiers/telegram_bot"
require "../../../src/cre/persistence/sqlite/sqlite_persistence"

WebMock.allow_net_connect = false

private def fresh_setup
  persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
  persist.migrate!
  bus = CRE::Engine::EventBus.new
  bus.run
  telegram = CRE::Notifiers::Telegram.new("FAKE")
  bot = CRE::Notifiers::TelegramBot.new(
    bus: bus,
    telegram: telegram,
    persistence: persist,
    viewer_chats: [100_i64],
    operator_chats: [200_i64],
  )
  {persist, bus, telegram, bot}
end

describe CRE::Notifiers::TelegramBot do
  it "viewer can run /status" do
    persist, bus, _, bot = fresh_setup
    reply = bot.handle_command(100_i64, "/status")
    reply.should contain "live"
    reply.should contain "Credentials"
  ensure
    bus.try(&.stop)
    persist.try(&.close)
  end

  it "viewer cannot /rotate" do
    persist, bus, _, bot = fresh_setup
    reply = bot.handle_command(100_i64, "/rotate 00000000-0000-0000-0000-000000000000")
    reply.should contain "operator-only"
  ensure
    bus.try(&.stop)
    persist.try(&.close)
  end

  it "operator can /rotate; publishes RotationScheduled" do
    persist, bus, _, bot = fresh_setup

    received = [] of CRE::Events::Event
    received_mutex = Mutex.new
    ch = bus.subscribe
    spawn do
      loop do
        begin
          ev = ch.receive
          received_mutex.synchronize { received << ev }
        rescue ::Channel::ClosedError
          break
        end
      end
    end

    cred_id = UUID.random
    reply = bot.handle_command(200_i64, "/rotate #{cred_id}")
    reply.should contain "rotation scheduled"
    sleep 0.1.seconds
    received_mutex.synchronize { received.any?(&.is_a?(CRE::Events::RotationScheduled)).should be_true }
  ensure
    bus.try(&.stop)
    persist.try(&.close)
  end

  it "unauthorized chat is blocked" do
    persist, bus, _, bot = fresh_setup
    bot.handle_command(999_i64, "/status").should eq "unauthorized"
  ensure
    bus.try(&.stop)
    persist.try(&.close)
  end

  it "/help lists commands" do
    persist, bus, _, bot = fresh_setup
    reply = bot.handle_command(100_i64, "/help")
    reply.should contain "/status"
    reply.should contain "/rotate"
  ensure
    bus.try(&.stop)
    persist.try(&.close)
  end
end
