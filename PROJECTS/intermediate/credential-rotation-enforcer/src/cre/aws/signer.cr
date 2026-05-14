# ===================
# ©AngelaMos | 2026
# signer.cr
# ===================

require "openssl/digest"
require "openssl/hmac"
require "uri"
require "http/headers"

module CRE::Aws
  class SignerError < Exception; end

  # SigV4 signer per AWS reference:
  # https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
  class SigV4
    ALGORITHM = "AWS4-HMAC-SHA256"

    def initialize(
      @access_key_id : String,
      @secret_access_key : String,
      @region : String,
      @service : String,
      @session_token : String? = nil,
    )
    end

    record SignedRequest, headers : HTTP::Headers, body : String

    # Returns the signed Authorization header value plus modified headers.
    # Mutates the headers map in-place to add 'X-Amz-Date', 'Host',
    # 'X-Amz-Content-SHA256', 'X-Amz-Security-Token' (if any), 'Authorization'.
    def sign(method : String, uri : URI, headers : HTTP::Headers, body : String, now : Time = Time.utc) : Nil
      amz_date = now.to_s("%Y%m%dT%H%M%SZ")
      date_stamp = now.to_s("%Y%m%d")

      headers["Host"] = uri.host.not_nil!
      headers["X-Amz-Date"] = amz_date
      headers["X-Amz-Security-Token"] = @session_token.not_nil! if @session_token
      payload_hash = sha256_hex(body)
      headers["X-Amz-Content-SHA256"] = payload_hash

      canonical_uri = canonical_path(uri.path.empty? ? "/" : uri.path)
      canonical_querystring = canonical_query(uri.query)
      canonical_headers, signed_headers = canonical_headers_and_list(headers)

      canonical_request = String.build do |s|
        s << method.upcase << '\n'
        s << canonical_uri << '\n'
        s << canonical_querystring << '\n'
        s << canonical_headers << '\n'
        s << signed_headers << '\n'
        s << payload_hash
      end

      credential_scope = "#{date_stamp}/#{@region}/#{@service}/aws4_request"
      string_to_sign = String.build do |s|
        s << ALGORITHM << '\n'
        s << amz_date << '\n'
        s << credential_scope << '\n'
        s << sha256_hex(canonical_request)
      end

      signing_key = derive_signing_key(date_stamp)
      signature = OpenSSL::HMAC.hexdigest(:sha256, signing_key, string_to_sign)

      auth = String.build do |s|
        s << ALGORITHM << ' '
        s << "Credential=" << @access_key_id << '/' << credential_scope << ", "
        s << "SignedHeaders=" << signed_headers << ", "
        s << "Signature=" << signature
      end
      headers["Authorization"] = auth
    end

    private def canonical_path(path : String) : String
      # AWS: encode each path segment per RFC 3986; '/' kept literal; double-encode for non-S3 services
      path.split('/', remove_empty: false).map { |seg| URI.encode_path_segment(seg) }.join('/')
    end

    private def canonical_query(query : String?) : String
      return "" unless query && !query.empty?
      params = [] of {String, String}
      query.split('&') do |pair|
        eq = pair.index('=')
        if eq
          k = URI.decode_www_form(pair[0, eq])
          v = URI.decode_www_form(pair[eq + 1..])
        else
          k = URI.decode_www_form(pair)
          v = ""
        end
        params << {k, v}
      end
      params.sort! { |a, b| a[0] <=> b[0] }
      params.map { |k, v| "#{URI.encode_path_segment(k)}=#{URI.encode_path_segment(v)}" }.join('&')
    end

    private def canonical_headers_and_list(headers : HTTP::Headers) : {String, String}
      sorted = headers.to_a.map { |name, values|
        {name.downcase, values.first.strip.gsub(/\s+/, " ")}
      }.sort_by { |entry| entry[0] }

      canonical = sorted.map { |k, v| "#{k}:#{v}\n" }.join
      list = sorted.map(&.[0]).join(';')
      {canonical, list}
    end

    private def derive_signing_key(date_stamp : String) : Bytes
      k_date = OpenSSL::HMAC.digest(:sha256, "AWS4#{@secret_access_key}".to_slice, date_stamp.to_slice)
      k_region = OpenSSL::HMAC.digest(:sha256, k_date, @region.to_slice)
      k_service = OpenSSL::HMAC.digest(:sha256, k_region, @service.to_slice)
      OpenSSL::HMAC.digest(:sha256, k_service, "aws4_request".to_slice)
    end

    private def sha256_hex(data : String) : String
      d = OpenSSL::Digest.new("SHA256")
      d.update(data)
      d.hexfinal
    end
  end
end
