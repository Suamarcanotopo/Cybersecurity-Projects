# ===================
# ©AngelaMos | 2026
# rotator_spec.cr
# ===================

require "../../spec_helper"
require "../../../src/cre/rotators/rotator"
require "../../../src/cre/rotators/env_file"

describe CRE::Rotators::Rotator do
  it "registers concrete rotator subclasses via register_as macro" do
    CRE::Rotators::Rotator::REGISTRY[:env_file]?.should_not be_nil
    CRE::Rotators::Rotator.for(:env_file).should eq CRE::Rotators::EnvFileRotator
    CRE::Rotators::Rotator.registered_kinds.should contain(:env_file)
  end

  it "for returns nil for unknown kinds" do
    CRE::Rotators::Rotator.for(:nonexistent).should be_nil
  end
end
