# ===================
# ©AngelaMos | 2026
# bundle.cr
# ===================

require "compress/zip"
require "json"
require "openssl/digest"
require "../persistence/persistence"
require "../persistence/repos"
require "../audit/signing"
require "./control_mapping"

module CRE::Compliance
  # Bundle assembles a self-verifying evidence ZIP for a compliance auditor.
  # Layout:
  #   evidence.zip/
  #     README.md                  - what's in here, how to verify
  #     manifest.json              - file checksums + signature
  #     audit_log.ndjson           - raw audit events with hash-chain fields
  #     audit_batches.json         - signed Merkle batch roots over the period
  #     public_key.pem             - Ed25519 public key (32 hex bytes; SHA-256
  #                                   covered by manifest so substitution shows
  #                                   up as a manifest checksum mismatch)
  #     control_mapping.json       - event_type -> framework controls
  class Bundle
    record FileEntry, name : String, sha256_hex : String, size : Int32

    def initialize(
      @persistence : Persistence::Persistence,
      @framework : String,
      @signer : Audit::Signing::Ed25519Signer? = nil,
      @public_key_hex : String? = nil,
    )
    end

    def write(path : String) : Nil
      File.open(path, "w") do |fp|
        Compress::Zip::Writer.open(fp) do |zip|
          # 1) build raw bytes for every file we plan to ship
          payload_files = [] of {String, String}
          payload_files << {"audit_log.ndjson", build_audit_log_ndjson}
          payload_files << {"audit_batches.json", build_audit_batches_json}
          payload_files << {"control_mapping.json", build_control_mapping_json}
          if pem = @public_key_hex
            payload_files << {"public_key.pem", pem}
          end

          # 2) compute checksums and build manifest covering ALL payload files
          #    (including public_key.pem so substitution invalidates the manifest sig)
          payload_entries = payload_files.map do |(name, content)|
            FileEntry.new(name: name, sha256_hex: sha256_hex(content), size: content.bytesize)
          end
          readme = build_readme(payload_entries)
          payload_files << {"README.md", readme}
          payload_entries << FileEntry.new(name: "README.md", sha256_hex: sha256_hex(readme), size: readme.bytesize)

          manifest = build_manifest(payload_entries)

          # 3) emit zip in dependency order
          payload_files.each { |(name, content)| add_file(zip, name, content) }
          add_file(zip, "manifest.json", manifest)
          if signer = @signer
            sig = signer.sign(manifest.to_slice)
            add_file(zip, "manifest.sig", Base64.encode(sig))
          end
        end
      end
    end

    private def add_file(zip, name : String, content : String) : Nil
      zip.add(name) { |io| io << content }
    end

    private def build_audit_log_ndjson : String
      latest = @persistence.audit.latest_seq
      return "" if latest == 0
      io = IO::Memory.new
      @persistence.audit.each_in_range(1_i64, latest) do |entry|
        row = {
          "seq"              => entry.seq,
          "event_id"         => entry.event_id.to_s,
          "occurred_at"      => entry.occurred_at.to_rfc3339,
          "event_type"       => entry.event_type,
          "actor"            => entry.actor,
          "target_id"        => entry.target_id.try(&.to_s),
          "payload"          => entry.payload,
          "prev_hash_hex"    => entry.prev_hash.hexstring,
          "content_hash_hex" => entry.content_hash.hexstring,
          "hmac_hex"         => entry.hmac.hexstring,
          "hmac_key_version" => entry.hmac_key_version,
        }
        row.to_json(io)
        io << '\n'
      end
      io.to_s
    end

    private def build_audit_batches_json : String
      batches = @persistence.audit.all_batches
      return "[]" if batches.empty?
      rows = batches.map do |b|
        {
          "id"                  => b.id.to_s,
          "start_seq"           => b.start_seq,
          "end_seq"             => b.end_seq,
          "merkle_root_hex"     => b.merkle_root.hexstring,
          "signature_hex"       => b.signature.hexstring,
          "signing_key_version" => b.signing_key_version,
          "sealed_at"           => b.sealed_at.to_rfc3339,
        }
      end
      rows.to_json
    end

    private def build_control_mapping_json : String
      ControlMapping.for(@framework).to_json
    end

    private def build_manifest(entries : Array(FileEntry)) : String
      {
        "framework" => @framework,
        "generated" => Time.utc.to_rfc3339,
        "files"     => entries.map { |e|
          {"name" => e.name, "sha256" => e.sha256_hex, "size" => e.size}
        },
      }.to_json
    end

    private def build_readme(_entries : Array(FileEntry)) : String
      <<-MD
      Credential Rotation Enforcer - Compliance Evidence Bundle

      Framework: #{@framework}
      Generated: #{Time.utc.to_rfc3339}

      Contents:
        - audit_log.ndjson      raw audit events with hash-chain fields
        - audit_batches.json    signed Merkle batches over the period
        - control_mapping.json  event_type -> framework controls
        - public_key.pem        Ed25519 public key (32 hex bytes)
        - manifest.json         per-file SHA-256 checksums (covers public_key.pem)
        - manifest.sig          Ed25519 signature of manifest.json (if signed)

      Verification:
        cre verify-bundle <this-zip>

      Manual verification:
        1. Recompute SHA-256 of every file listed in manifest.json and compare.
        2. Verify manifest.sig over manifest.json using public_key.pem.
        3. Walk audit_log.ndjson and recompute the hash chain - each row's
           content_hash should equal SHA256(prev_hash || canonical(payload)).
        4. For each row in audit_batches.json, recompute the Merkle root over
           content_hashes in [start_seq, end_seq] and verify signature_hex
           with public_key.pem.

      Note on public_key.pem trust:
        The bundled public key is fingerprint-protected by manifest.json's
        SHA-256 entry. The manifest itself is Ed25519-signed; if an adversary
        substitutes the key+sig pair, manifest.json's checksum no longer
        matches the bundled file. Auditors should still verify the in-bundle
        public key's SHA-256 against an out-of-band fingerprint they trust.
      MD
    end

    private def sha256_hex(content : String) : String
      d = OpenSSL::Digest.new("SHA256")
      d.update(content)
      d.hexfinal
    end
  end
end
