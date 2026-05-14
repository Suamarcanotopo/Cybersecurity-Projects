# ===================
# ©AngelaMos | 2026
# tier_1_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/demo/tier_1"

describe CRE::Demo::Tier1 do
  it "runs end-to-end and reports rotation success" do
    io = IO::Memory.new
    code = CRE::Demo::Tier1.run(io)
    code.should eq 0

    out = CRE::Tui::Ansi.strip(io.to_s)
    out.should contain "Tier 1 demo"
    out.should contain "BEFORE"
    out.should contain "AFTER"
    out.should contain "rotation completed"
    out.should contain "audit events, hash chain valid"
  end
end
