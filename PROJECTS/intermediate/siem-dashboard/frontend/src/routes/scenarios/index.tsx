// ===================
// ©AngelaMos | 2026
// index.tsx
//
// Scenario runner page showing available playbooks and active scenario controls
//
// The running section only renders when there are active runs. Each running
// scenario renders as a RunningCard with pause/resume, stop, and speed
// selector controls. The playbook grid shows static metadata (event count,
// MITRE tactics and techniques) and a start button for each playbook.
// RunningCard is an internal helper component.
//
// Key components:
//   Component - lazy-loaded scenarios page; displayName "Scenarios"
//
// Connects to:
//   useScenarios.ts - playbook list, running scenarios, and control mutations
//   scenario.types.ts - ScenarioRun, PlaybookInfo types
//   config.ts - SCENARIO_STATUS_LABELS for display strings
// ===================

import { LuPause, LuPlay, LuSquare } from 'react-icons/lu'
import {
  useAvailablePlaybooks,
  usePauseScenario,
  useResumeScenario,
  useRunningScenarios,
  useSetScenarioSpeed,
  useStartScenario,
  useStopScenario,
} from '@/api/hooks'
import type { ScenarioRun } from '@/api/types'
import { SCENARIO_STATUS_LABELS } from '@/config'
import styles from './scenarios.module.scss'

const RUN_STATUS_STYLE: Record<string, string> = {
  running: styles.runRunning,
  paused: styles.runPaused,
  completed: styles.runCompleted,
  stopped: styles.runStopped,
  error: styles.runError,
}

export function Component(): React.ReactElement {
  const { data: playbooks, isLoading: loadingPlaybooks } = useAvailablePlaybooks()
  const { data: running } = useRunningScenarios()
  const startScenario = useStartScenario()

  return (
    <div className={styles.page}>
      {running && running.length > 0 && (
        <section>
          <h2 className={styles.sectionTitle}>Running Scenarios</h2>
          <div className={styles.runningList}>
            {running.map((run) => (
              <RunningCard key={run.id} run={run} />
            ))}
          </div>
        </section>
      )}

      <section>
        <h2 className={styles.sectionTitle}>Available Playbooks</h2>
        <div className={styles.playbookGrid}>
          {loadingPlaybooks ? (
            Array.from({ length: 4 }, (_, i) => (
              <div key={`skel-${i}`} className={styles.cardSkeleton} />
            ))
          ) : playbooks?.length === 0 ? (
            <div className={styles.empty}>No playbooks found</div>
          ) : (
            playbooks?.map((pb) => (
              <div key={pb.filename} className={styles.playbookCard}>
                <h3 className={styles.playbookName}>{pb.name}</h3>
                <p className={styles.playbookDesc}>{pb.description}</p>
                <div className={styles.playbookMeta}>
                  <span>{pb.event_count} events</span>
                  {pb.mitre_tactics.length > 0 && (
                    <span className={styles.tactic}>
                      {pb.mitre_tactics.join(', ')}
                    </span>
                  )}
                </div>
                {pb.mitre_techniques.length > 0 && (
                  <div className={styles.techniques}>
                    {pb.mitre_techniques.map((t) => (
                      <span key={t} className={styles.technique}>
                        {t}
                      </span>
                    ))}
                  </div>
                )}
                <button
                  type="button"
                  className={styles.startBtn}
                  disabled={startScenario.isPending}
                  onClick={() => startScenario.mutate({ filename: pb.filename })}
                >
                  <LuPlay />
                  Start
                </button>
              </div>
            ))
          )}
        </div>
      </section>
    </div>
  )
}

Component.displayName = 'Scenarios'

function RunningCard({ run }: { run: ScenarioRun }): React.ReactElement {
  const stop = useStopScenario()
  const pause = usePauseScenario()
  const resume = useResumeScenario()
  const setSpeed = useSetScenarioSpeed(run.id)

  const isPaused = run.status === 'paused'
  const isActive = run.status === 'running' || run.status === 'paused'

  return (
    <div className={styles.runningCard}>
      <div className={styles.runningHeader}>
        <h3 className={styles.runningName}>{run.scenario_name}</h3>
        <span
          className={`${styles.statusBadge} ${RUN_STATUS_STYLE[run.status] ?? ''}`}
        >
          {SCENARIO_STATUS_LABELS[run.status] ?? run.status}
        </span>
      </div>
      <div className={styles.runningStats}>
        <span>{run.events_generated} events</span>
        <span>{run.speed}x speed</span>
        <span>
          {new Date(run.started_at).toLocaleTimeString([], {
            hour: '2-digit',
            minute: '2-digit',
          })}
        </span>
      </div>
      {isActive && (
        <div className={styles.controls}>
          <button
            type="button"
            className={styles.controlBtn}
            onClick={() =>
              isPaused ? resume.mutate(run.id) : pause.mutate(run.id)
            }
            disabled={pause.isPending || resume.isPending}
          >
            {isPaused ? <LuPlay /> : <LuPause />}
          </button>
          <button
            type="button"
            className={styles.controlBtn}
            onClick={() => stop.mutate(run.id)}
            disabled={stop.isPending}
          >
            <LuSquare />
          </button>
          <select
            className={styles.speedSelect}
            value={run.speed}
            onChange={(e) =>
              setSpeed.mutate({ speed: parseFloat(e.target.value) })
            }
          >
            <option value="0.5">0.5x</option>
            <option value="1">1x</option>
            <option value="1.5">1.5x</option>
            <option value="2">2x</option>
            <option value="3">3x</option>
            <option value="5">5x</option>
          </select>
        </div>
      )}
      {run.error_message && (
        <p className={styles.errorMsg}>{run.error_message}</p>
      )}
    </div>
  )
}
