# ===================
# ©AngelaMos | 2026
# dsl.cr
# ===================

require "./builder"
require "./policy"

module CRE::Policy::Dsl
  # Top-level-feeling DSL for declaring policies. Users opt in:
  #
  #     require "cre/policy/dsl"
  #     include CRE::Policy::Dsl
  #
  #     policy "production-aws-secrets" do
  #       description "All prod AWS secrets rotate every 30 days"
  #       match { |c| c.kind.aws_secretsmgr? && c.tag(:env) == "prod" }
  #       max_age 30.days
  #       enforce :rotate_immediately
  #       notify_via :telegram, :structured_log
  #     end
  #
  # Single-symbol args (`enforce :rotate_immediately`) autocast to enum
  # values via Crystal's parameter typing — typos like
  # `enforce :rotate_immediatly` fail at compile time. Splat-symbol args
  # (`notify_via :telegram, :structured_log`) are validated at policy
  # registration time and raise `BuilderError` on typos.
  def policy(name : String, &block)
    builder = CRE::Policy::Builder.new(name)
    with builder yield
    CRE::Policy::REGISTRY << builder.build
  end
end
