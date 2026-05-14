# ===================
# ©AngelaMos | 2026
# event.cr
# ===================

require "uuid"

module CRE::Events
  abstract class Event
    getter id : UUID = UUID.random
    getter occurred_at : Time = Time.utc
  end
end
