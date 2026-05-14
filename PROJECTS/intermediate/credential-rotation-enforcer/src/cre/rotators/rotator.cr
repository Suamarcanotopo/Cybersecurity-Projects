# ===================
# ©AngelaMos | 2026
# rotator.cr
# ===================

require "../domain/credential"
require "../domain/new_secret"

module CRE::Rotators
  class RotatorError < Exception; end

  abstract class Rotator
    REGISTRY = {} of Symbol => Rotator.class

    abstract def kind : Symbol
    abstract def can_rotate?(c : Domain::Credential) : Bool

    abstract def generate(c : Domain::Credential) : Domain::NewSecret
    abstract def apply(c : Domain::Credential, s : Domain::NewSecret) : Nil
    abstract def verify(c : Domain::Credential, s : Domain::NewSecret) : Bool
    abstract def commit(c : Domain::Credential, s : Domain::NewSecret) : Nil

    # Default no-op; rotators override when apply() creates reversible side effects.
    def rollback_apply(c : Domain::Credential, s : Domain::NewSecret) : Nil
    end

    macro register_as(kind)
      ::CRE::Rotators::Rotator::REGISTRY[{{ kind }}] = self
    end

    def self.for(kind : Symbol) : Rotator.class | Nil
      REGISTRY[kind]?
    end

    def self.registered_kinds : Array(Symbol)
      REGISTRY.keys
    end
  end
end
