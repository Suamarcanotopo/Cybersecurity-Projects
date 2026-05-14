// ===================
// ©AngelaMos | 2026
// index.tsx
//
// Log viewer page with source/severity filters, event type search, and detail drawer
//
// Source type and severity dropdowns narrow the paginated log list. The search
// input filters by event_type. Clicking a table row fetches the full event
// via useLogDetail and renders a side drawer showing all fields including
// normalized and raw JSON blobs. LogDetail and DetailField are internal helpers.
//
// Key components:
//   Component - lazy-loaded log viewer page; displayName "LogViewer"
//
// Connects to:
//   useLogs.ts - paginated log list with source/severity filtering
//   log.types.ts - LogEvent, LogQueryParams types
//   config.ts - SEVERITY_LABELS for display strings
// ===================

import { useState } from 'react'
import { LuChevronLeft, LuChevronRight, LuSearch, LuX } from 'react-icons/lu'
import { useLogDetail, useLogs } from '@/api/hooks'
import type { LogEvent, LogQueryParams } from '@/api/types'
import { SEVERITY_LABELS } from '@/config'
import styles from './logs.module.scss'

const SOURCE_OPTIONS = [
  'firewall',
  'ids',
  'auth',
  'endpoint',
  'dns',
  'proxy',
  'generic',
]

const SEVERITY_OPTIONS = ['critical', 'high', 'medium', 'low', 'info']

export function Component(): React.ReactElement {
  const [page, setPage] = useState(1)
  const [sourceType, setSourceType] = useState('')
  const [severity, setSeverity] = useState('')
  const [search, setSearch] = useState('')
  const [selectedId, setSelectedId] = useState<string | null>(null)

  const params: LogQueryParams = {
    page,
    per_page: 25,
    ...(sourceType && { source_type: sourceType }),
    ...(severity && { severity }),
    ...(search && { event_type: search }),
  }

  const { data, isLoading } = useLogs(params)
  const detail = useLogDetail(selectedId ?? '')

  return (
    <div className={styles.page}>
      <div className={styles.filters}>
        <div className={styles.filterGroup}>
          <select
            className={styles.select}
            value={sourceType}
            onChange={(e) => {
              setSourceType(e.target.value)
              setPage(1)
            }}
          >
            <option value="">All Sources</option>
            {SOURCE_OPTIONS.map((t) => (
              <option key={t} value={t}>
                {t}
              </option>
            ))}
          </select>
          <select
            className={styles.select}
            value={severity}
            onChange={(e) => {
              setSeverity(e.target.value)
              setPage(1)
            }}
          >
            <option value="">All Severities</option>
            {SEVERITY_OPTIONS.map((s) => (
              <option key={s} value={s}>
                {SEVERITY_LABELS[s] ?? s}
              </option>
            ))}
          </select>
        </div>

        <div className={styles.searchWrapper}>
          <LuSearch className={styles.searchIcon} />
          <input
            type="text"
            className={styles.searchInput}
            placeholder="Filter by event type..."
            value={search}
            onChange={(e) => {
              setSearch(e.target.value)
              setPage(1)
            }}
          />
          {search && (
            <button
              type="button"
              className={styles.clearBtn}
              onClick={() => setSearch('')}
            >
              <LuX />
            </button>
          )}
        </div>
      </div>

      <div className={styles.tableWrapper}>
        <table className={styles.table}>
          <thead>
            <tr>
              <th>Timestamp</th>
              <th>Severity</th>
              <th>Source</th>
              <th>Event Type</th>
              <th>Source IP</th>
              <th>Dest IP</th>
              <th>Username</th>
            </tr>
          </thead>
          <tbody>
            {isLoading ? (
              Array.from({ length: 10 }, (_, i) => (
                <tr key={`skel-${i}`}>
                  <td colSpan={7}>
                    <div className={styles.skeleton} />
                  </td>
                </tr>
              ))
            ) : data?.items.length === 0 ? (
              <tr>
                <td colSpan={7} className={styles.empty}>
                  No log events found
                </td>
              </tr>
            ) : (
              data?.items.map((log) => (
                <tr
                  key={log.id}
                  className={`${styles.row} ${selectedId === log.id ? styles.selected : ''}`}
                  onClick={() =>
                    setSelectedId(selectedId === log.id ? null : log.id)
                  }
                >
                  <td className={styles.mono}>
                    {new Date(log.timestamp).toLocaleString([], {
                      month: 'short',
                      day: '2-digit',
                      hour: '2-digit',
                      minute: '2-digit',
                      second: '2-digit',
                    })}
                  </td>
                  <td>
                    <span className={`${styles.badge} ${styles[log.severity]}`}>
                      {log.severity}
                    </span>
                  </td>
                  <td>{log.source_type}</td>
                  <td>{log.event_type ?? '\u2014'}</td>
                  <td className={styles.mono}>{log.source_ip ?? '\u2014'}</td>
                  <td className={styles.mono}>{log.dest_ip ?? '\u2014'}</td>
                  <td>{log.username ?? '\u2014'}</td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>

      {selectedId && detail.data && (
        <LogDetail log={detail.data} onClose={() => setSelectedId(null)} />
      )}

      {data && data.pages > 1 && (
        <div className={styles.pagination}>
          <button
            type="button"
            className={styles.pageBtn}
            disabled={page <= 1}
            onClick={() => setPage(page - 1)}
          >
            <LuChevronLeft />
          </button>
          <span className={styles.pageInfo}>
            {page} / {data.pages}
          </span>
          <button
            type="button"
            className={styles.pageBtn}
            disabled={page >= data.pages}
            onClick={() => setPage(page + 1)}
          >
            <LuChevronRight />
          </button>
        </div>
      )}
    </div>
  )
}

Component.displayName = 'LogViewer'

function LogDetail({
  log,
  onClose,
}: {
  log: LogEvent
  onClose: () => void
}): React.ReactElement {
  return (
    <div className={styles.detail}>
      <div className={styles.detailHeader}>
        <h3 className={styles.detailTitle}>Event Detail</h3>
        <button type="button" className={styles.closeBtn} onClick={onClose}>
          <LuX />
        </button>
      </div>
      <div className={styles.detailGrid}>
        <DetailField label="ID" value={log.id} />
        <DetailField
          label="Timestamp"
          value={new Date(log.timestamp).toLocaleString()}
        />
        <DetailField label="Source Type" value={log.source_type} />
        <DetailField label="Severity" value={log.severity} />
        <DetailField label="Event Type" value={log.event_type} />
        <DetailField label="Source IP" value={log.source_ip} />
        <DetailField label="Dest IP" value={log.dest_ip} />
        <DetailField label="Source Port" value={log.source_port?.toString()} />
        <DetailField label="Dest Port" value={log.dest_port?.toString()} />
        <DetailField label="Hostname" value={log.hostname} />
        <DetailField label="Username" value={log.username} />
        <DetailField label="MITRE Tactic" value={log.mitre_tactic} />
        <DetailField label="MITRE Technique" value={log.mitre_technique} />
      </div>
      {Object.keys(log.normalized).length > 0 && (
        <div className={styles.detailSection}>
          <h4 className={styles.detailSectionTitle}>Normalized</h4>
          <pre className={styles.detailPre}>
            {JSON.stringify(log.normalized, null, 2)}
          </pre>
        </div>
      )}
      {Object.keys(log.raw).length > 0 && (
        <div className={styles.detailSection}>
          <h4 className={styles.detailSectionTitle}>Raw</h4>
          <pre className={styles.detailPre}>
            {JSON.stringify(log.raw, null, 2)}
          </pre>
        </div>
      )}
    </div>
  )
}

function DetailField({
  label,
  value,
}: {
  label: string
  value: string | null | undefined
}): React.ReactElement | null {
  if (value === null || value === undefined) return null
  return (
    <div className={styles.detailField}>
      <span className={styles.detailLabel}>{label}</span>
      <span className={styles.detailValue}>{value}</span>
    </div>
  )
}
