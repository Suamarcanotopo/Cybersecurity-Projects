# ===================
# ©AngelaMos | 2026
# control_mapping.cr
# ===================

module CRE::Compliance
  # ControlMapping is the lookup that turns audit event_types into the specific
  # framework controls they satisfy. The mapping is intentionally opinionated -
  # each event maps only to controls where it provides direct evidence, not
  # speculative coverage.
  module ControlMapping
    SOC2 = {
      "rotation.completed"      => ["CC6.1", "CC6.6"],
      "rotation.failed"         => ["CC6.6", "CC7.2"],
      "rotation.step.completed" => ["CC6.1"],
      "rotation.step.failed"    => ["CC6.6", "CC7.2"],
      "policy.violation"        => ["CC6.7", "CC7.2"],
      "drift.detected"          => ["CC6.6", "CC7.2"],
      "audit.batch.sealed"      => ["CC4.1", "CC7.1"],
      "key.rotation.kek"        => ["CC6.1"],
      "credential.discovered"   => ["CC6.1"],
      "alert.raised"            => ["CC7.2"],
    }

    PCI_DSS = {
      "rotation.completed" => ["8.3.9", "8.6.3"],
      "rotation.failed"    => ["8.3.9", "10.2.1"],
      "policy.violation"   => ["8.6.3", "10.2.1"],
      "drift.detected"     => ["10.2.1", "11.5.2"],
      "audit.batch.sealed" => ["10.5.2", "10.5.3"],
      "key.rotation.kek"   => ["3.7.4"],
    }

    ISO27001 = {
      "rotation.completed" => ["A.5.16", "A.5.17"],
      "rotation.failed"    => ["A.5.17", "A.8.5"],
      "policy.violation"   => ["A.5.18"],
      "drift.detected"     => ["A.8.16"],
      "audit.batch.sealed" => ["A.8.15"],
      "key.rotation.kek"   => ["A.8.24"],
    }

    HIPAA = {
      "rotation.completed" => ["164.308(a)(5)(ii)(D)"],
      "rotation.failed"    => ["164.308(a)(5)(ii)(D)", "164.308(a)(6)(ii)"],
      "policy.violation"   => ["164.308(a)(5)(ii)(D)"],
      "drift.detected"     => ["164.308(a)(6)(ii)"],
      "audit.batch.sealed" => ["164.312(b)"],
    }

    def self.for(framework : String) : Hash(String, Array(String))
      case framework.downcase
      when "soc2"     then SOC2
      when "pci_dss"  then PCI_DSS
      when "iso27001" then ISO27001
      when "hipaa"    then HIPAA
      else
        raise ArgumentError.new("unknown framework: #{framework} (valid: soc2, pci_dss, iso27001, hipaa)")
      end
    end

    def self.frameworks : Array(String)
      %w[soc2 pci_dss iso27001 hipaa]
    end
  end
end
