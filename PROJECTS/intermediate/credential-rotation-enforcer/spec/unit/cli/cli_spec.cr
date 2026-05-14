# ===================
# ©AngelaMos | 2026
# cli_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/cli/cli"

describe CRE::Cli do
  it "prints usage when no args given and exits 64" do
    io = IO::Memory.new
    code = CRE::Cli.dispatch([] of String, io)
    code.should eq 64
    io.to_s.should contain "Subcommands"
  end

  it "prints usage on help" do
    io = IO::Memory.new
    code = CRE::Cli.dispatch(["help"], io)
    code.should eq 0
    io.to_s.should contain "Subcommands"
  end

  it "prints version on version subcommand" do
    io = IO::Memory.new
    code = CRE::Cli.dispatch(["version"], io)
    code.should eq 0
    io.to_s.strip.should eq CRE::VERSION
  end

  it "policy list works against an empty registry" do
    CRE::Policy.clear_registry!
    io = IO::Memory.new
    code = CRE::Cli.dispatch(["policy", "list"], io)
    code.should eq 0
    io.to_s.should contain "no policies"
  end

  it "policy show returns 1 on missing policy" do
    CRE::Policy.clear_registry!
    io = IO::Memory.new
    code = CRE::Cli.dispatch(["policy", "show", "nonexistent"], io)
    code.should eq 1
  end

  it "rejects unknown subcommands" do
    io = IO::Memory.new
    code = CRE::Cli.dispatch(["thisisbad"], io)
    code.should eq 64
    io.to_s.should contain "unknown subcommand"
  end

  it "check on empty db returns 0 (no violations)" do
    io = IO::Memory.new
    code = CRE::Cli.dispatch(["check", "--db=:memory:"], io)
    code.should eq 0
  end
end
