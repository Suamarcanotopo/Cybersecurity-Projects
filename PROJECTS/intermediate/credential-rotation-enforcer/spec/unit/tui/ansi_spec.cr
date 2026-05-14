# ===================
# ©AngelaMos | 2026
# ansi_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/tui/ansi"

describe CRE::Tui::Ansi do
  it "wraps text with color escape codes" do
    out = CRE::Tui::Ansi.green("hello")
    out.should contain "\e[32m"
    out.should contain "hello"
    out.should end_with "\e[0m"
  end

  it "move produces a CSI cursor-position sequence" do
    CRE::Tui::Ansi.move(5, 10).should eq "\e[5;10H"
  end

  it "strip removes escape sequences" do
    raw = "\e[1m\e[33mwarn\e[0m message"
    CRE::Tui::Ansi.strip(raw).should eq "warn message"
  end
end
