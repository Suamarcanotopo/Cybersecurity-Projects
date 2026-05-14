# ===================
# ©AngelaMos | 2026
# telegram_spec.cr
# ===================

require "../../spec_helper"
require "webmock"
require "../../../src/cre/notifiers/telegram"
require "../../../src/cre/notifiers/telegram_subscriber"
require "../../../src/cre/events/credential_events"

WebMock.allow_net_connect = false

describe CRE::Notifiers::Telegram do
  before_each { WebMock.reset }

  it "sends a message" do
    sent_body = nil
    WebMock.stub(:post, "https://api.telegram.org/botFAKE/sendMessage")
      .to_return { |req| sent_body = req.body.try(&.gets_to_end); HTTP::Client::Response.new(200, body: %({"ok":true})) }
    CRE::Notifiers::Telegram.new("FAKE").send_message(12345_i64, "hello world")
    sent_body.try(&.includes?("hello world")).should be_true
    sent_body.try(&.includes?(%("chat_id":12345))).should be_true
  end

  it "raises TelegramError on non-2xx" do
    WebMock.stub(:post, "https://api.telegram.org/botFAKE/sendMessage")
      .to_return(status: 401, body: %({"ok":false,"description":"Unauthorized"}))
    expect_raises(CRE::Notifiers::Telegram::TelegramError) do
      CRE::Notifiers::Telegram.new("FAKE").send_message(1_i64, "x")
    end
  end

  it "parses getUpdates with messages" do
    WebMock.stub(:post, "https://api.telegram.org/botFAKE/getUpdates")
      .to_return(body: %({
        "ok":true,
        "result":[{
          "update_id":42,
          "message":{
            "message_id":7,
            "chat":{"id":99},
            "text":"/status"
          }
        }]
      }))
    updates = CRE::Notifiers::Telegram.new("FAKE").get_updates
    updates.size.should eq 1
    updates[0].chat_id.should eq 99
    updates[0].text.should eq "/status"
  end
end

describe CRE::Notifiers::TelegramSubscriber do
  before_each { WebMock.reset }

  it "fires Telegram message on RotationFailed" do
    sent = [] of String
    WebMock.stub(:post, "https://api.telegram.org/botFAKE/sendMessage")
      .to_return { |req|
        body = req.body.try(&.gets_to_end) || ""
        sent << body
        HTTP::Client::Response.new(200, body: %({"ok":true}))
      }

    bus = CRE::Engine::EventBus.new
    sub = CRE::Notifiers::TelegramSubscriber.new(
      bus, CRE::Notifiers::Telegram.new("FAKE"), [12345_i64],
    )
    sub.start
    bus.run

    bus.publish CRE::Events::RotationFailed.new(UUID.random, UUID.random, "boom")
    sleep 0.1.seconds

    sent.size.should eq 1
    sent[0].should contain "FAILED"
  ensure
    bus.try(&.stop)
    sub.try(&.stop)
  end

  it "does not fire on RotationCompleted unless notify_on_success" do
    sent = [] of String
    WebMock.stub(:post, "https://api.telegram.org/botFAKE/sendMessage")
      .to_return { |req| sent << (req.body.try(&.gets_to_end) || ""); HTTP::Client::Response.new(200, body: %({"ok":true})) }

    bus = CRE::Engine::EventBus.new
    sub = CRE::Notifiers::TelegramSubscriber.new(
      bus, CRE::Notifiers::Telegram.new("FAKE"), [1_i64], notify_on_success: false)
    sub.start
    bus.run
    bus.publish CRE::Events::RotationCompleted.new(UUID.random, UUID.random)
    sleep 0.1.seconds
    sent.size.should eq 0
  ensure
    bus.try(&.stop)
    sub.try(&.stop)
  end
end
