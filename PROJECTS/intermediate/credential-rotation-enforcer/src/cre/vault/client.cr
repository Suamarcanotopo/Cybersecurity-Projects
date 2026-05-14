# ===================
# ©AngelaMos | 2026
# client.cr
# ===================

require "http/client"
require "json"
require "../http/retry"

module CRE::Vault
  class VaultError < Exception
    getter status : Int32

    def initialize(message : String, @status : Int32)
      super(message)
    end
  end

  class Client
    record DynamicSecret,
      lease_id : String,
      lease_duration : Int32,
      username : String,
      password : String

    def initialize(@addr : String, @token : String)
    end

    def read_dynamic(role_path : String) : DynamicSecret
      json = http_get("/v1/#{role_path}")
      data = json["data"]
      lease_id = json["lease_id"].as_s
      lease_duration = json["lease_duration"].as_i
      DynamicSecret.new(
        lease_id: lease_id,
        lease_duration: lease_duration,
        username: data["username"].as_s,
        password: data["password"].as_s,
      )
    end

    def revoke_lease(lease_id : String) : Nil
      http_put("/v1/sys/leases/revoke", {"lease_id" => lease_id}.to_json)
    end

    def renew_lease(lease_id : String, increment : Int32 = 0) : Int32
      payload = increment > 0 ? {"lease_id" => lease_id, "increment" => increment} : {"lease_id" => lease_id}
      json = http_put("/v1/sys/leases/renew", payload.to_json)
      json["lease_duration"].as_i
    end

    def health : Hash(String, JSON::Any)
      json = http_get("/v1/sys/health")
      json.as_h
    end

    private def http_get(path : String) : JSON::Any
      headers = HTTP::Headers{"X-Vault-Token" => @token}
      response = CRE::Http.request("GET", @addr + path, headers, label: "vault.GET#{path}")
      raise VaultError.new("vault GET #{path}: #{response.body[0, 200]?}", response.status_code) unless response.status_code < 300
      JSON.parse(response.body)
    end

    private def http_put(path : String, body : String) : JSON::Any
      headers = HTTP::Headers{
        "X-Vault-Token" => @token,
        "Content-Type"  => "application/json",
      }
      response = CRE::Http.request("PUT", @addr + path, headers, body, label: "vault.PUT#{path}")
      raise VaultError.new("vault PUT #{path}: #{response.body[0, 200]?}", response.status_code) unless response.status_code < 300
      response.body.empty? ? JSON::Any.new(Hash(String, JSON::Any).new) : JSON.parse(response.body)
    end
  end
end
