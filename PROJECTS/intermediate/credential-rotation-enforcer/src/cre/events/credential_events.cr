# ===================
# ©AngelaMos | 2026
# credential_events.cr
# ===================

require "uuid"
require "./event"

module CRE::Events
  abstract class CredentialEvent < Event
    getter credential_id : UUID

    def initialize(@credential_id : UUID)
      super()
    end
  end

  class CredentialDiscovered < CredentialEvent
  end

  class PolicyViolation < CredentialEvent
    getter policy_name : String
    getter reason : String

    def initialize(credential_id : UUID, @policy_name : String, @reason : String)
      super(credential_id)
    end
  end

  class RotationScheduled < CredentialEvent
    getter rotator_kind : String

    def initialize(credential_id : UUID, @rotator_kind : String)
      super(credential_id)
    end
  end

  class RotationStarted < CredentialEvent
    getter rotation_id : UUID
    getter rotator_kind : String

    def initialize(credential_id : UUID, @rotation_id : UUID, @rotator_kind : String)
      super(credential_id)
    end
  end

  class RotationStepStarted < CredentialEvent
    getter rotation_id : UUID
    getter step : Symbol

    def initialize(credential_id : UUID, @rotation_id : UUID, @step : Symbol)
      super(credential_id)
    end
  end

  class RotationStepCompleted < CredentialEvent
    getter rotation_id : UUID
    getter step : Symbol

    def initialize(credential_id : UUID, @rotation_id : UUID, @step : Symbol)
      super(credential_id)
    end
  end

  class RotationStepFailed < CredentialEvent
    getter rotation_id : UUID
    getter step : Symbol
    getter error : String

    def initialize(credential_id : UUID, @rotation_id : UUID, @step : Symbol, @error : String)
      super(credential_id)
    end
  end

  class RotationCompleted < CredentialEvent
    getter rotation_id : UUID

    def initialize(credential_id : UUID, @rotation_id : UUID)
      super(credential_id)
    end
  end

  class RotationFailed < CredentialEvent
    getter rotation_id : UUID
    getter reason : String

    def initialize(credential_id : UUID, @rotation_id : UUID, @reason : String)
      super(credential_id)
    end
  end

  class DriftDetected < CredentialEvent
    getter expected_hash : String
    getter actual_hash : String

    def initialize(credential_id : UUID, @expected_hash : String, @actual_hash : String)
      super(credential_id)
    end
  end
end
