# ===================
# ©AngelaMos | 2026
# control_mapping_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/compliance/control_mapping"

describe CRE::Compliance::ControlMapping do
  it "maps SOC2 controls" do
    map = CRE::Compliance::ControlMapping.for("soc2")
    map["rotation.completed"].should contain "CC6.1"
    map["rotation.completed"].should contain "CC6.6"
    map["audit.batch.sealed"].should contain "CC4.1"
  end

  it "maps PCI-DSS controls" do
    map = CRE::Compliance::ControlMapping.for("pci_dss")
    map["rotation.completed"].should contain "8.3.9"
    map["audit.batch.sealed"].should contain "10.5.2"
  end

  it "raises on unknown framework" do
    expect_raises(ArgumentError) { CRE::Compliance::ControlMapping.for("not-real") }
  end

  it "lists frameworks" do
    CRE::Compliance::ControlMapping.frameworks.should contain "soc2"
    CRE::Compliance::ControlMapping.frameworks.should contain "pci_dss"
  end
end
