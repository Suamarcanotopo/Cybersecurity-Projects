// ©AngelaMos | 2026
// Panel.tsx

import type { ReactNode } from 'react'
import { FiExternalLink } from 'react-icons/fi'
import styles from './Panel.module.scss'
import { StaleIndicator } from './shared/StaleIndicator'

export type PanelAccent =
  | 'bgp'
  | 'outage'
  | 'kev'
  | 'ransomware'
  | 'dshield'
  | 'quake'
  | 'iss'
  | 'spacewx'
  | 'cve'
  | 'wiki'
  | 'btc'
  | 'eth'

export interface PanelProps {
  title: string
  subtitle?: string
  source?: string
  accent?: PanelAccent
  rawHref?: string
  rawLabel?: string
  isStale?: boolean
  lastTickAt?: number
  batch?: boolean
  children: ReactNode
}

export function Panel({
  title,
  subtitle,
  source,
  accent,
  rawHref,
  rawLabel,
  isStale,
  lastTickAt,
  batch,
  children,
}: PanelProps): React.ReactElement {
  const ACCENT_CLASS: Record<PanelAccent, string> = {
    bgp: styles.accentBgp,
    outage: styles.accentOutage,
    kev: styles.accentKev,
    ransomware: styles.accentRansomware,
    dshield: styles.accentDshield,
    quake: styles.accentQuake,
    iss: styles.accentIss,
    spacewx: styles.accentSpacewx,
    cve: styles.accentCve,
    wiki: styles.accentWiki,
    btc: styles.accentBtc,
    eth: styles.accentEth,
  }
  const accentClass = accent ? ACCENT_CLASS[accent] : ''
  const panelClass = [styles.panel, accentClass].filter(Boolean).join(' ')

  return (
    <article className={panelClass}>
      <header className={styles.head}>
        <span className={styles.titleBlock}>
          <span className={styles.title}>
            {title}
            {subtitle && <span className={styles.subtitle}> · {subtitle}</span>}
          </span>
          {source && <span className={styles.source}>{source}</span>}
        </span>
        <span className={styles.meta}>
          <StaleIndicator stale={isStale} lastTickAt={lastTickAt} batch={batch} />
          {rawHref && (
            <a
              className={styles.rawLink}
              href={rawHref}
              target="_blank"
              rel="noreferrer noopener"
              aria-label={rawLabel ?? 'Raw source'}
            >
              <FiExternalLink aria-hidden />
            </a>
          )}
        </span>
      </header>
      <div className={styles.body}>{children}</div>
    </article>
  )
}

Panel.displayName = 'Panel'
