# ===================
# ©AngelaMos | 2026
# system_events.cr
# ===================

require "./event"

module CRE::Events
  enum Severity
    Info
    Warn
    Critical
  end

  class AlertRaised < Event
    getter severity : Severity
    getter message : String

    def initialize(@severity : Severity, @message : String)
      super()
    end
  end

  class SchedulerTick < Event
  end

  class ShutdownRequested < Event
  end

  class AuditBatchSealed < Event
    getter start_seq : Int64
    getter end_seq : Int64
    getter signing_key_version : Int32

    def initialize(@start_seq : Int64, @end_seq : Int64, @signing_key_version : Int32)
      super()
    end
  end
end
