# ===================
# ©AngelaMos | 2026
# output.cr
# ===================

require "json"

module CRE::Cli
  enum OutputFormat
    Human
    Json
    Ndjson
  end

  module Output
    def self.parse_format(s : String) : OutputFormat
      case s.downcase
      when "human"  then OutputFormat::Human
      when "json"   then OutputFormat::Json
      when "ndjson" then OutputFormat::Ndjson
      else
        raise "unknown output format: #{s} (valid: human, json, ndjson)"
      end
    end

    def self.print(io : IO, format : OutputFormat, data) : Nil
      case format
      in OutputFormat::Human
        io.puts data.to_s
      in OutputFormat::Json
        io.puts data.to_json
      in OutputFormat::Ndjson
        if data.is_a?(Array)
          data.each { |row| io.puts row.to_json }
        else
          io.puts data.to_json
        end
      end
    end
  end
end
