# ===================
# ©AngelaMos | 2026
# bundle_spec.cr
# ===================

require "../../spec_helper"
require "compress/zip"
require "../../../src/cre/compliance/bundle"
require "../../../src/cre/audit/audit_log"
require "../../../src/cre/persistence/sqlite/sqlite_persistence"

private def fresh_persistence
  persist = CRE::Persistence::Sqlite::SqlitePersistence.new(":memory:")
  persist.migrate!
  persist
end

describe CRE::Compliance::Bundle do
  it "writes a zip with required files" do
    persist = fresh_persistence
    log = CRE::Audit::AuditLog.new(persist, Bytes.new(32, 0_u8), 1, 1024)
    log.append("rotation.completed", "system", UUID.random, {"k" => "v"})
    log.append("policy.violation", "system", UUID.random, {"r" => "stale"})

    out_path = File.tempname("evidence", ".zip")
    bundle = CRE::Compliance::Bundle.new(persist, "soc2")
    bundle.write(out_path)

    File.exists?(out_path).should be_true

    names = [] of String
    Compress::Zip::File.open(out_path) do |zip|
      zip.entries.each { |e| names << e.filename }
    end

    names.should contain "audit_log.ndjson"
    names.should contain "audit_batches.json"
    names.should contain "control_mapping.json"
    names.should contain "manifest.json"
    names.should contain "README.md"
  ensure
    File.delete(out_path) if out_path && File.exists?(out_path)
    persist.try(&.close)
  end

  it "manifest.json lists every file with sha256" do
    persist = fresh_persistence
    log = CRE::Audit::AuditLog.new(persist, Bytes.new(32, 0_u8), 1, 1024)
    log.append("test", "system", nil, {"x" => "y"})

    out_path = File.tempname("evidence-m", ".zip")
    CRE::Compliance::Bundle.new(persist, "soc2").write(out_path)

    manifest_text = ""
    Compress::Zip::File.open(out_path) do |zip|
      manifest_text = zip.entries.find!(&.filename.==("manifest.json")).open(&.gets_to_end)
    end

    parsed = JSON.parse(manifest_text)
    parsed["framework"].as_s.should eq "soc2"
    parsed["files"].as_a.size.should be > 0
    parsed["files"].as_a.each do |f|
      f["sha256"].as_s.size.should eq 64
    end
  ensure
    File.delete(out_path) if out_path && File.exists?(out_path)
    persist.try(&.close)
  end

  it "control_mapping.json carries the right framework controls" do
    persist = fresh_persistence
    out_path = File.tempname("evidence-cm", ".zip")
    CRE::Compliance::Bundle.new(persist, "pci_dss").write(out_path)

    cm = ""
    Compress::Zip::File.open(out_path) do |zip|
      cm = zip.entries.find!(&.filename.==("control_mapping.json")).open(&.gets_to_end)
    end

    parsed = JSON.parse(cm)
    parsed["rotation.completed"].as_a.map(&.as_s).should contain "8.3.9"
  ensure
    File.delete(out_path) if out_path && File.exists?(out_path)
    persist.try(&.close)
  end
end
