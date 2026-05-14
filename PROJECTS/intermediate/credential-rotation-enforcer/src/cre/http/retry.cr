# ===================
# ©AngelaMos | 2026
# retry.cr
# ===================

require "http/client"
require "log"

module CRE::Http
  # Transient HTTP statuses where retrying makes sense. We do NOT retry
  # on 401/403/404 — those mean the request is bad, not flaky.
  RETRY_STATUSES = {408, 425, 429, 500, 502, 503, 504}.to_set

  # Retry wraps a Proc with bounded retry-with-jitter. Default policy:
  # 3 attempts (initial + 2 retries), 200ms..2s exponential backoff with
  # full jitter, retries network errors and the canonical transient
  # statuses listed above.
  module Retry
    Log = ::Log.for("cre.http.retry")

    def self.with(
      *,
      attempts : Int32 = 3,
      base_delay : Time::Span = 200.milliseconds,
      max_delay : Time::Span = 2.seconds,
      retry_statuses : Set(Int32) = RETRY_STATUSES,
      label : String = "http",
      &block : -> HTTP::Client::Response
    ) : HTTP::Client::Response
      attempt = 0
      loop do
        attempt += 1
        begin
          response = block.call
          if retry_statuses.includes?(response.status_code) && attempt < attempts
            Log.warn { "#{label}: HTTP #{response.status_code} on attempt #{attempt}; retrying" }
            sleep_with_jitter(base_delay, max_delay, attempt)
            next
          end
          return response
        rescue ex : IO::TimeoutError | Socket::ConnectError | IO::Error
          if attempt < attempts
            Log.warn(exception: ex) { "#{label}: transient error on attempt #{attempt}; retrying" }
            sleep_with_jitter(base_delay, max_delay, attempt)
            next
          end
          raise ex
        end
      end
    end

    private def self.sleep_with_jitter(base : Time::Span, ceiling : Time::Span, attempt : Int32) : Nil
      backoff_ms = base.total_milliseconds * (1 << (attempt - 1))
      capped_ms = Math.min(backoff_ms, ceiling.total_milliseconds)
      jittered = (capped_ms * Random.rand).to_i
      sleep jittered.milliseconds
    end
  end

  # Connect/read timeouts come from env so operators can tune per
  # environment without recompiling. Defaults are conservative for cloud
  # APIs where 5xx blips are normal.
  CONNECT_TIMEOUT = ((ENV["CRE_HTTP_CONNECT_TIMEOUT_S"]? || "5").to_f).seconds
  READ_TIMEOUT    = ((ENV["CRE_HTTP_READ_TIMEOUT_S"]? || "30").to_f).seconds

  # Single-shot HTTP request with timeouts + retry. Returns the
  # HTTP::Client::Response. The HTTP::Client instance is created per
  # call and closed in an ensure block so a hung peer can't pin
  # resources past the timeout. Webmock intercepts via instance method
  # override so test stubs continue to apply unchanged.
  def self.request(method : String, url : String, headers : HTTP::Headers, body : String = "", label : String = "http") : HTTP::Client::Response
    uri = URI.parse(url)
    request_target = String.build do |s|
      s << (uri.path.empty? ? "/" : uri.path)
      if (q = uri.query) && !q.empty?
        s << "?" << q
      end
    end
    Retry.with(label: label) do
      client = HTTP::Client.new(uri)
      client.connect_timeout = CONNECT_TIMEOUT
      client.read_timeout = READ_TIMEOUT
      begin
        client.exec(method, request_target, headers: headers, body: body)
      ensure
        client.close
      end
    end
  end
end
