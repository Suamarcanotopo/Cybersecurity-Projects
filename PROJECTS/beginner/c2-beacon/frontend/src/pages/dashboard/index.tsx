// ===========================
// © AngelaMos | 2026
// pages/dashboard/index.tsx
//
// Operator dashboard listing all known beacons with live status
//
// Renders a table of every beacon the C2 server has seen. Active status
// and last-seen timestamps update in real time via the operator
// WebSocket. Clicking a row navigates to the session page for that
// beacon. An empty state is shown when no beacons are registered.
//
// Key components:
//   Component (Dashboard) - lazy-loaded route component for /
//
// Connects to:
//   config.ts - reads ROUTES.SESSION for row navigation
//   core/types.ts - imports BeaconRecord
//   core/ws.ts - calls useBeacons, useIsConnected, useOperatorSocket
// ===========================

import { useEffect, useState } from 'react'
import { LuCircle, LuRadar } from 'react-icons/lu'
import { useNavigate } from 'react-router-dom'
import { ROUTES } from '@/config'
import type { BeaconRecord } from '@/core/types'
import { useBeacons, useIsConnected, useOperatorSocket } from '@/core/ws'
import styles from './dashboard.module.scss'

function formatRelativeTime(iso: string): string {
  const diff = Math.floor((Date.now() - new Date(iso).getTime()) / 1000)
  if (diff < 5) return 'just now'
  if (diff < 60) return `${diff}s ago`
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`
  return `${Math.floor(diff / 86400)}d ago`
}

function isOnline(lastSeen: string): boolean {
  return Date.now() - new Date(lastSeen).getTime() < 30_000
}

function truncateId(id: string): string {
  return id.length > 8 ? `${id.slice(0, 8)}...` : id
}

function StatusDot({ connected }: { connected: boolean }): React.ReactElement {
  return (
    <span
      className={`${styles.statusDot} ${connected ? styles.online : styles.offline}`}
      role="img"
      aria-label={connected ? 'Connected' : 'Disconnected'}
    >
      <LuCircle />
    </span>
  )
}

function BeaconRow({
  beacon,
  onClick,
}: {
  beacon: BeaconRecord
  onClick: () => void
}): React.ReactElement {
  const online = beacon.active && isOnline(beacon.last_seen)

  return (
    <tr
      className={styles.row}
      onClick={onClick}
      onKeyDown={(e) => e.key === 'Enter' && onClick()}
      tabIndex={0}
    >
      <td className={styles.cellId}>{truncateId(beacon.id)}</td>
      <td>{beacon.hostname}</td>
      <td>{beacon.os}</td>
      <td>{beacon.username}</td>
      <td className={styles.cellMono}>{beacon.internal_ip}</td>
      <td className={styles.cellMono}>{formatRelativeTime(beacon.last_seen)}</td>
      <td>
        <span
          className={`${styles.badge} ${online ? styles.badgeOnline : styles.badgeOffline}`}
        >
          {online ? 'online' : 'offline'}
        </span>
      </td>
    </tr>
  )
}

function EmptyState(): React.ReactElement {
  return (
    <div className={styles.empty}>
      <LuRadar className={styles.emptyIcon} />
      <p className={styles.emptyTitle}>No beacons connected</p>
      <p className={styles.emptyDesc}>
        Start a beacon implant to see it appear here in real-time.
      </p>
    </div>
  )
}

export function Component(): React.ReactElement {
  useOperatorSocket()
  const beacons = useBeacons()
  const connected = useIsConnected()
  const navigate = useNavigate()
  const [, setTick] = useState(0)

  useEffect(() => {
    const interval = setInterval(() => setTick((t) => t + 1), 1000)
    return () => clearInterval(interval)
  }, [])

  return (
    <div className={styles.page}>
      <div className={styles.container}>
        <div className={styles.header}>
          <div className={styles.headerLeft}>
            <h1 className={styles.title}>Operator Dashboard</h1>
            <StatusDot connected={connected} />
          </div>
          <span className={styles.count}>
            <span className={styles.countValue}>{beacons.length}</span> beacon
            {beacons.length !== 1 ? 's' : ''}
          </span>
        </div>

        {beacons.length === 0 ? (
          <EmptyState />
        ) : (
          <div className={styles.tableWrap}>
            <table className={styles.table}>
              <thead>
                <tr>
                  <th>ID</th>
                  <th>Hostname</th>
                  <th>OS</th>
                  <th>User</th>
                  <th>IP</th>
                  <th>Last Seen</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {beacons.map((b) => (
                  <BeaconRow
                    key={b.id}
                    beacon={b}
                    onClick={() => navigate(ROUTES.SESSION(b.id))}
                  />
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  )
}

Component.displayName = 'Dashboard'
