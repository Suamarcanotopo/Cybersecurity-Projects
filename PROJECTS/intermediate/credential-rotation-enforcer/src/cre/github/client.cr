# ===================
# ©AngelaMos | 2026
# client.cr
# ===================

require "http/client"
require "json"
require "../http/retry"

module CRE::Github
  class GithubError < Exception
    getter status : Int32

    def initialize(message : String, @status : Int32)
      super(message)
    end
  end

  # Thin GitHub REST client. We target fine-grained PATs for rotation since
  # the /user/personal-access-tokens endpoint accepts programmatic creation
  # and deletion when the bearer has the appropriate Apps-managed
  # permission. For the test/portfolio path we mock these endpoints
  # directly.
  class Client
    record Token, id : Int64, token_value : String, expires_at : String?

    DEFAULT_API = "https://api.github.com"

    def initialize(@token : String, @api_base : String = DEFAULT_API)
    end

    def me : JSON::Any
      get("/user")
    end

    def create_pat(name : String, scopes : Array(String), expires_in_days : Int32 = 90) : Token
      payload = {
        "name"            => name,
        "expires_in_days" => expires_in_days,
        "scopes"          => scopes,
      }.to_json
      json = post("/user/personal-access-tokens", payload)
      Token.new(
        id: json["id"].as_i64,
        token_value: json["token"].as_s,
        expires_at: json["expires_at"]?.try(&.as_s),
      )
    end

    def delete_pat(token_id : Int64) : Nil
      delete("/user/personal-access-tokens/#{token_id}")
    end

    private def get(path : String) : JSON::Any
      response = CRE::Http.request("GET", url(path), headers, label: "github.GET#{path}")
      raise GithubError.new("GET #{path}: #{response.body[0, 200]?}", response.status_code) unless response.status_code < 300
      JSON.parse(response.body)
    end

    private def post(path : String, body : String) : JSON::Any
      response = CRE::Http.request("POST", url(path), headers, body, label: "github.POST#{path}")
      raise GithubError.new("POST #{path}: #{response.body[0, 200]?}", response.status_code) unless response.status_code < 300
      JSON.parse(response.body)
    end

    private def delete(path : String) : Nil
      response = CRE::Http.request("DELETE", url(path), headers, label: "github.DELETE#{path}")
      raise GithubError.new("DELETE #{path}: #{response.body[0, 200]?}", response.status_code) unless response.status_code < 300
    end

    private def headers : HTTP::Headers
      HTTP::Headers{
        "Authorization"        => "Bearer #{@token}",
        "Accept"               => "application/vnd.github+json",
        "X-GitHub-Api-Version" => "2022-11-28",
        "Content-Type"         => "application/json",
      }
    end

    private def url(path : String) : String
      "#{@api_base}#{path}"
    end
  end
end
