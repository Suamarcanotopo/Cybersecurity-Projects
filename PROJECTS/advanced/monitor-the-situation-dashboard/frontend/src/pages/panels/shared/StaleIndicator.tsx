// ©AngelaMos | 2026
// StaleIndicator.tsx

import styles from './StaleIndicator.module.scss'

export interface StaleIndicatorProps {
  stale?: boolean
  lastTickAt?: number
  batch?: boolean
}

export function StaleIndicator({
  stale,
  lastTickAt,
  batch,
}: StaleIndicatorProps): React.ReactElement {
  let state: 'live' | 'batch' | 'stale'
  if (stale === undefined || stale === true) {
    state = 'stale'
  } else if (batch) {
    state = 'batch'
  } else {
    state = 'live'
  }
  const className = `${styles.dot} ${styles[state]}`

  const title = lastTickAt
    ? `Last update ${new Date(lastTickAt).toISOString().slice(11, 19)} UTC`
    : undefined

  return <span className={className} title={title} aria-hidden />
}

StaleIndicator.displayName = 'StaleIndicator'
