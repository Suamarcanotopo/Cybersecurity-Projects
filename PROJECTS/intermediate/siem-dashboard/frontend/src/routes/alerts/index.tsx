// ===================
// ©AngelaMos | 2026
// index.tsx
//
// Alert list page with status filtering, detail panel, and lifecycle actions
//
// STATUS_TABS drives a tab bar that filters alerts by lifecycle state.
// Clicking an alert row toggles an inline detail panel showing matched log
// events and status transition buttons. AlertDetailPanel uses useAlertDetail
// to fetch the full alert with matched events, and useUpdateAlertStatus to
// patch the status. AlertCard and InfoField are internal helper components.
//
// Key components:
//   Component - lazy-loaded alerts page; displayName "Alerts"
//
// Connects to:
//   useAlerts.ts - paginated alert list with status filtering
//   alert.types.ts - Alert, AlertDetail types
//   config.ts - ALERT_STATUS_LABELS, SEVERITY_LABELS
// ===================

import { useState } from 'react'
import { LuChevronLeft, LuChevronRight, LuX } from 'react-icons/lu'
import { useAlertDetail, useAlerts, useUpdateAlertStatus } from '@/api/hooks'
import type { Alert } from '@/api/types'
import { ALERT_STATUS_LABELS, SEVERITY_LABELS } from '@/config'
import styles from './alerts.module.scss'

const STATUS_STYLE: Record<string, string> = {
  new: styles.statusNew,
  acknowledged: styles.statusAcknowledged,
  investigating: styles.statusInvestigating,
  resolved: styles.statusResolved,
  false_positive: styles.statusFalsePositive,
}

const STATUS_TABS = [
  { value: '', label: 'All' },
  { value: 'new', label: 'New' },
  { value: 'acknowledged', label: 'Acknowledged' },
  { value: 'investigating', label: 'Investigating' },
  { value: 'resolved', label: 'Resolved' },
]

export function Component(): React.ReactElement {
  const [page, setPage] = useState(1)
  const [statusFilter, setStatusFilter] = useState('')
  const [selectedId, setSelectedId] = useState<string | null>(null)

  const { data, isLoading } = useAlerts({
    page,
    per_page: 25,
    ...(statusFilter && { status: statusFilter }),
  })

  return (
    <div className={styles.page}>
      <div className={styles.tabs}>
        {STATUS_TABS.map((tab) => (
          <button
            key={tab.value}
            type="button"
            className={`${styles.tab} ${statusFilter === tab.value ? styles.active : ''}`}
            onClick={() => {
              setStatusFilter(tab.value)
              setPage(1)
            }}
          >
            {tab.label}
          </button>
        ))}
      </div>

      <div className={styles.list}>
        {isLoading ? (
          Array.from({ length: 5 }, (_, i) => (
            <div key={`skel-${i}`} className={styles.cardSkeleton} />
          ))
        ) : data?.items.length === 0 ? (
          <div className={styles.empty}>No alerts found</div>
        ) : (
          data?.items.map((alert) => (
            <AlertCard
              key={alert.id}
              alert={alert}
              isSelected={selectedId === alert.id}
              onSelect={() =>
                setSelectedId(selectedId === alert.id ? null : alert.id)
              }
            />
          ))
        )}
      </div>

      {selectedId && (
        <AlertDetailPanel
          alertId={selectedId}
          onClose={() => setSelectedId(null)}
        />
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

Component.displayName = 'Alerts'

function AlertCard({
  alert,
  isSelected,
  onSelect,
}: {
  alert: Alert
  isSelected: boolean
  onSelect: () => void
}): React.ReactElement {
  return (
    <button
      type="button"
      className={`${styles.card} ${isSelected ? styles.selected : ''}`}
      onClick={onSelect}
    >
      <div className={styles.cardTop}>
        <span className={`${styles.severityBadge} ${styles[alert.severity]}`}>
          {alert.severity}
        </span>
        <span
          className={`${styles.statusBadge} ${STATUS_STYLE[alert.status] ?? ''}`}
        >
          {ALERT_STATUS_LABELS[alert.status] ?? alert.status}
        </span>
      </div>
      <h3 className={styles.cardTitle}>{alert.title}</h3>
      <div className={styles.cardMeta}>
        <span>{alert.rule_name}</span>
        <span>{alert.matched_event_count} events</span>
        <span>
          {new Date(alert.created_at).toLocaleString([], {
            month: 'short',
            day: '2-digit',
            hour: '2-digit',
            minute: '2-digit',
          })}
        </span>
      </div>
      {alert.mitre_technique && (
        <span className={styles.mitre}>{alert.mitre_technique}</span>
      )}
    </button>
  )
}

function AlertDetailPanel({
  alertId,
  onClose,
}: {
  alertId: string
  onClose: () => void
}): React.ReactElement {
  const { data, isLoading } = useAlertDetail(alertId)
  const updateStatus = useUpdateAlertStatus(alertId)

  if (isLoading || !data) {
    return (
      <div className={styles.detail}>
        <div className={styles.detailSkeleton} />
      </div>
    )
  }

  const { alert, matched_events } = data

  const statusActions = [
    { status: 'acknowledged', label: 'Acknowledge' },
    { status: 'investigating', label: 'Investigate' },
    { status: 'resolved', label: 'Resolve' },
    { status: 'false_positive', label: 'False Positive' },
  ].filter((a) => a.status !== alert.status)

  return (
    <div className={styles.detail}>
      <div className={styles.detailHeader}>
        <h3 className={styles.detailTitle}>{alert.title}</h3>
        <button type="button" className={styles.closeBtn} onClick={onClose}>
          <LuX />
        </button>
      </div>

      <div className={styles.detailInfo}>
        <InfoField label="Rule" value={alert.rule_name} />
        <InfoField
          label="Severity"
          value={SEVERITY_LABELS[alert.severity] ?? alert.severity}
        />
        <InfoField
          label="Status"
          value={ALERT_STATUS_LABELS[alert.status] ?? alert.status}
        />
        <InfoField label="Group" value={alert.group_value} />
        <InfoField label="Events" value={alert.matched_event_count.toString()} />
        <InfoField
          label="Created"
          value={new Date(alert.created_at).toLocaleString()}
        />
        {alert.mitre_tactic && (
          <InfoField label="MITRE Tactic" value={alert.mitre_tactic} />
        )}
        {alert.mitre_technique && (
          <InfoField label="MITRE Technique" value={alert.mitre_technique} />
        )}
        {alert.acknowledged_by && (
          <InfoField label="Acknowledged By" value={alert.acknowledged_by} />
        )}
        {alert.notes && <InfoField label="Notes" value={alert.notes} />}
      </div>

      <div className={styles.actions}>
        {statusActions.map((action) => (
          <button
            key={action.status}
            type="button"
            className={styles.actionBtn}
            disabled={updateStatus.isPending}
            onClick={() => updateStatus.mutate({ status: action.status })}
          >
            {action.label}
          </button>
        ))}
      </div>

      {matched_events.length > 0 && (
        <div className={styles.matchedEvents}>
          <h4 className={styles.matchedTitle}>
            Matched Events ({matched_events.length})
          </h4>
          <div className={styles.eventList}>
            {matched_events.slice(0, 20).map((event) => (
              <div key={event.id} className={styles.eventRow}>
                <span className={styles.eventTime}>
                  {new Date(event.timestamp).toLocaleTimeString([], {
                    hour: '2-digit',
                    minute: '2-digit',
                    second: '2-digit',
                  })}
                </span>
                <span
                  className={`${styles.severityBadge} ${styles[event.severity]}`}
                >
                  {event.severity}
                </span>
                <span className={styles.eventType}>
                  {event.event_type ?? '\u2014'}
                </span>
                <span className={styles.eventIp}>
                  {event.source_ip ?? '\u2014'}
                </span>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  )
}

function InfoField({
  label,
  value,
}: {
  label: string
  value: string | null | undefined
}): React.ReactElement | null {
  if (value === null || value === undefined) return null
  return (
    <div className={styles.infoField}>
      <span className={styles.infoLabel}>{label}</span>
      <span className={styles.infoValue}>{value}</span>
    </div>
  )
}
