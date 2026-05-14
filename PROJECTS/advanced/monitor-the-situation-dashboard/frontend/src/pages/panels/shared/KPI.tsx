// ©AngelaMos | 2026
// KPI.tsx

import type { ReactNode } from 'react'
import styles from './KPI.module.scss'

export interface KPIProps {
  label: string
  value: ReactNode
}

export function KPI({ label, value }: KPIProps): React.ReactElement {
  return (
    <div className={styles.kpi}>
      <div className={styles.value}>{value}</div>
      <div className={styles.label}>{label}</div>
    </div>
  )
}

KPI.displayName = 'KPI'
