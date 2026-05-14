# ===================
# ©AngelaMos | 2026
# verify_bundle.cr
# ===================

require "compress/zip"
require "json"
require "openssl/digest"
require "../../audit/hash_chain"
require "../../audit/signing"
require "../../audit/merkle"

module CRE::Cli::Commands
  # VerifyBundle reads a compliance evidence ZIP produced by 'cre export'
  # and re-runs every check the bundle's README documents:
  #
  #   1. Per-file SHA-256 vs manifest.json
  #   2. Manifest Ed25519 signature vs public_key.pem (if both present)
  #   3. Audit log hash chain reconstruction
  #   4. Audit batch Merkle-root + signature reconstruction
  #
  # Exit codes:
  #   0  - all checks passed
  #   2  - one or more checks failed
  #   64 - usage error
  class VerifyBundle
    def execute(argv : Array(String), io : IO) : Int32
      _help_requested = false
      bundle_path = nil

      OptionParser.parse(argv) do |parser|
        parser.banner = "Usage: cre verify-bundle <evidence.zip>"
        parser.on("-h", "--help") { _help_requested = true; io.puts parser }
        parser.unknown_args { |args| bundle_path = args.first? }
      end
      return 0 if _help_requested

      if bundle_path.nil?
        io.puts "usage: cre verify-bundle <evidence.zip>"
        return 64
      end
      bundle = bundle_path.not_nil!

      unless File.exists?(bundle)
        io.puts "bundle not found: #{bundle}"
        return 2
      end

      contents = read_zip(bundle)
      manifest_text = contents["manifest.json"]?
      if manifest_text.nil?
        io.puts "✗ bundle is missing manifest.json"
        return 2
      end
      manifest = JSON.parse(manifest_text)

      checks_passed = true
      checks_passed &= verify_checksums(io, contents, manifest)
      checks_passed &= verify_manifest_signature(io, contents, manifest_text)
      checks_passed &= verify_hash_chain(io, contents)
      checks_passed &= verify_batches(io, contents)

      if checks_passed
        io.puts "✓ bundle valid"
        0
      else
        io.puts "✗ bundle FAILED verification"
        2
      end
    end

    private def read_zip(path : String) : Hash(String, String)
      out = {} of String => String
      Compress::Zip::File.open(path) do |zip|
        zip.entries.each do |entry|
          out[entry.filename] = entry.open(&.gets_to_end)
        end
      end
      out
    end

    private def verify_checksums(io : IO, contents : Hash(String, String), manifest : JSON::Any) : Bool
      ok = true
      manifest["files"].as_a.each do |entry|
        name = entry["name"].as_s
        expected = entry["sha256"].as_s
        body = contents[name]?
        if body.nil?
          io.puts "  ✗ checksum: missing #{name}"
          ok = false
          next
        end
        actual = sha256_hex(body)
        if actual != expected
          io.puts "  ✗ checksum mismatch on #{name}: expected #{expected}, got #{actual}"
          ok = false
        end
      end
      io.puts "  ✓ #{manifest["files"].as_a.size} file checksums match" if ok
      ok
    end

    private def verify_manifest_signature(io : IO, contents : Hash(String, String), manifest_text : String) : Bool
      sig_b64 = contents["manifest.sig"]?
      pubkey_hex = contents["public_key.pem"]?
      if sig_b64.nil? || pubkey_hex.nil?
        io.puts "  - manifest.sig / public_key.pem absent — signature step skipped"
        return true
      end

      sig = Base64.decode(sig_b64.strip)
      key_bytes = pubkey_hex.strip.hexbytes
      verifier = CRE::Audit::Signing::Ed25519Verifier.new(key_bytes)
      if verifier.verify(manifest_text.to_slice, sig)
        io.puts "  ✓ manifest signature valid"
        true
      else
        io.puts "  ✗ manifest signature INVALID"
        false
      end
    rescue ex
      io.puts "  ✗ manifest signature verification error: #{ex.message}"
      false
    end

    private def verify_hash_chain(io : IO, contents : Hash(String, String)) : Bool
      ndjson = contents["audit_log.ndjson"]?
      if ndjson.nil? || ndjson.empty?
        io.puts "  - audit_log.ndjson empty — hash chain step skipped"
        return true
      end

      prev = Bytes.new(32, 0_u8)
      lineno = 0
      ndjson.each_line do |line|
        lineno += 1
        next if line.empty?
        row = JSON.parse(line)
        # The exporter writes 'payload' as the canonical JSON the log used
        # when computing content_hash, so we hash that string verbatim.
        canonical = row["payload"].as_s
        expected = CRE::Audit::HashChain.next_hash(prev, canonical.to_slice)
        actual = row["content_hash_hex"].as_s.hexbytes
        unless expected == actual
          io.puts "  ✗ hash chain broken at seq=#{row["seq"]?} (line #{lineno})"
          return false
        end
        prev = actual
      end
      io.puts "  ✓ hash chain valid (#{lineno} entries)"
      true
    end

    private def verify_batches(io : IO, contents : Hash(String, String)) : Bool
      batches_json = contents["audit_batches.json"]?
      pubkey_hex = contents["public_key.pem"]?
      if batches_json.nil? || batches_json == "[]"
        io.puts "  - audit_batches.json empty — batch verify skipped"
        return true
      end
      if pubkey_hex.nil?
        io.puts "  ✗ batches present but public_key.pem absent — cannot verify"
        return false
      end

      verifier = CRE::Audit::Signing::Ed25519Verifier.new(pubkey_hex.strip.hexbytes)
      ndjson = contents["audit_log.ndjson"]? || ""
      content_hashes_by_seq = {} of Int64 => Bytes
      ndjson.each_line do |line|
        next if line.empty?
        row = JSON.parse(line)
        content_hashes_by_seq[row["seq"].as_i64] = row["content_hash_hex"].as_s.hexbytes
      end

      batches = JSON.parse(batches_json).as_a
      batches.each do |b|
        start_seq = b["start_seq"].as_i64
        end_seq = b["end_seq"].as_i64
        leaves = (start_seq..end_seq).map do |seq|
          h = content_hashes_by_seq[seq]?
          if h.nil?
            io.puts "  ✗ batch covers seq=#{seq} but ndjson is missing it"
            return false
          end
          h
        end
        recomputed = CRE::Audit::Merkle.root(leaves)
        stored = b["merkle_root_hex"].as_s.hexbytes
        unless recomputed == stored
          io.puts "  ✗ Merkle root mismatch on batch [#{start_seq}..#{end_seq}]"
          return false
        end
        msg = pack_batch_message(start_seq, end_seq, stored)
        sig = b["signature_hex"].as_s.hexbytes
        unless verifier.verify(msg, sig)
          io.puts "  ✗ batch signature invalid for [#{start_seq}..#{end_seq}]"
          return false
        end
      end
      io.puts "  ✓ #{batches.size} audit batches verified"
      true
    end

    private def pack_batch_message(start_seq : Int64, end_seq : Int64, root : Bytes) : Bytes
      io = IO::Memory.new
      io.write_bytes(start_seq, IO::ByteFormat::BigEndian)
      io.write_bytes(end_seq, IO::ByteFormat::BigEndian)
      io.write(root)
      io.to_slice
    end

    private def sha256_hex(content : String) : String
      d = OpenSSL::Digest.new("SHA256")
      d.update(content)
      d.hexfinal
    end
  end
end
