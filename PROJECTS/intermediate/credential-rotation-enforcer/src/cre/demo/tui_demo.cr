# ===================
# ©AngelaMos | 2026
# tui_demo.cr
# ===================

require "../engine/event_bus"
require "../tui/tui"
require "../events/credential_events"
require "../events/system_events"

module CRE::Demo
  # TuiDemo synthesizes a stream of fake events so you can SEE what the
  # live TUI looks like without running the full daemon. Eight seconds of
  # narrated activity, then it shuts down cleanly.
  module TuiDemo
    def self.run(io : IO = STDOUT, seconds : Int32 = 8) : Int32
      bus = CRE::Engine::EventBus.new
      tui = CRE::Tui::Tui.new(bus, io: io, refresh_interval: 150.milliseconds)
      bus.run
      tui.start

      script_fiber = spawn do
        run_script(bus, seconds)
      end

      sleep seconds.seconds + 0.5.seconds
      tui.stop
      bus.stop
      0
    end

    private def self.run_script(bus : CRE::Engine::EventBus, seconds : Int32) : Nil
      cred_a = UUID.random
      cred_b = UUID.random
      cred_c = UUID.random
      cred_d = UUID.random

      # 0.5s: a policy violation arrives
      sleep 0.5.seconds
      bus.publish CRE::Events::PolicyViolation.new(cred_a, "production-databases", "credential exceeded max_age=30.days (last rotated 47 days ago)")

      # 1.0s: rotation A starts
      sleep 0.5.seconds
      rot_a = UUID.random
      bus.publish CRE::Events::RotationStarted.new(cred_a, rot_a, "aws_secretsmgr")
      bus.publish CRE::Events::RotationStepStarted.new(cred_a, rot_a, :generate)

      # 1.5s: drift detected on B
      sleep 0.5.seconds
      bus.publish CRE::Events::DriftDetected.new(cred_b, "abc123def456", "ffe098cba321")

      # 2.0s: rotation A finishes generate, starts apply
      sleep 0.5.seconds
      bus.publish CRE::Events::RotationStepCompleted.new(cred_a, rot_a, :generate)
      bus.publish CRE::Events::RotationStepStarted.new(cred_a, rot_a, :apply)

      # 2.5s: rotation A finishes apply, starts verify
      sleep 0.5.seconds
      bus.publish CRE::Events::RotationStepCompleted.new(cred_a, rot_a, :apply)
      bus.publish CRE::Events::RotationStepStarted.new(cred_a, rot_a, :verify)

      # 3.0s: rotation C starts (parallel)
      sleep 0.5.seconds
      rot_c = UUID.random
      bus.publish CRE::Events::RotationStarted.new(cred_c, rot_c, "github_pat")
      bus.publish CRE::Events::RotationStepStarted.new(cred_c, rot_c, :generate)

      # 3.5s: rotation A finishes verify, starts commit
      sleep 0.5.seconds
      bus.publish CRE::Events::RotationStepCompleted.new(cred_a, rot_a, :verify)
      bus.publish CRE::Events::RotationStepStarted.new(cred_a, rot_a, :commit)

      # 4.0s: rotation A complete!
      sleep 0.5.seconds
      bus.publish CRE::Events::RotationStepCompleted.new(cred_a, rot_a, :commit)
      bus.publish CRE::Events::RotationCompleted.new(cred_a, rot_a)

      # 4.5s: alert + a fourth rotation (vault) starts
      sleep 0.5.seconds
      bus.publish CRE::Events::AlertRaised.new(CRE::Events::Severity::Warn, "5 credentials approaching expiry within 7 days")
      rot_d = UUID.random
      bus.publish CRE::Events::RotationStarted.new(cred_d, rot_d, "vault_dynamic")
      bus.publish CRE::Events::RotationStepStarted.new(cred_d, rot_d, :generate)

      # 5.0s: rotation C finishes generate, then fails on apply
      sleep 0.5.seconds
      bus.publish CRE::Events::RotationStepCompleted.new(cred_c, rot_c, :generate)
      bus.publish CRE::Events::RotationStepStarted.new(cred_c, rot_c, :apply)

      # 5.5s: rotation C apply fails!
      sleep 0.5.seconds
      bus.publish CRE::Events::RotationStepFailed.new(cred_c, rot_c, :apply, "GitHub API 403 - PAT lacks admin:org scope")
      bus.publish CRE::Events::RotationFailed.new(cred_c, rot_c, "GitHub API 403 - PAT lacks admin:org scope")

      # 6.0s: rotation D progresses
      sleep 0.5.seconds
      bus.publish CRE::Events::RotationStepCompleted.new(cred_d, rot_d, :generate)
      bus.publish CRE::Events::RotationStepStarted.new(cred_d, rot_d, :apply)
      bus.publish CRE::Events::RotationStepCompleted.new(cred_d, rot_d, :apply)
      bus.publish CRE::Events::RotationStepStarted.new(cred_d, rot_d, :verify)

      # 6.5s: critical alert
      sleep 0.5.seconds
      bus.publish CRE::Events::AlertRaised.new(CRE::Events::Severity::Critical, "1 critical: rotation_failure github_pat/deploy-bot needs manual intervention")

      # 7.0s: rotation D finishes
      sleep 0.5.seconds
      bus.publish CRE::Events::RotationStepCompleted.new(cred_d, rot_d, :verify)
      bus.publish CRE::Events::RotationStepStarted.new(cred_d, rot_d, :commit)
      bus.publish CRE::Events::RotationStepCompleted.new(cred_d, rot_d, :commit)
      bus.publish CRE::Events::RotationCompleted.new(cred_d, rot_d)
    rescue ex
      # silence: we may be torn down mid-script
    end
  end
end
