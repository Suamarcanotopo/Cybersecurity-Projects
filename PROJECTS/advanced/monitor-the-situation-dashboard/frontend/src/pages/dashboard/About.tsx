// ©AngelaMos | 2026
// About.tsx

import { useEffect, useRef } from 'react'
import { FiX } from 'react-icons/fi'
import { useUIStore } from '@/stores/ui'
import styles from './About.module.scss'

export function About(): React.ReactElement {
  const isOpen = useUIStore((s) => s.aboutOpen)
  const close = useUIStore((s) => s.closeAbout)
  const dialogRef = useRef<HTMLDialogElement>(null)

  useEffect(() => {
    const dialog = dialogRef.current
    if (!dialog) return
    if (isOpen && !dialog.open) {
      dialog.showModal()
    } else if (!isOpen && dialog.open) {
      dialog.close()
    }
  }, [isOpen])

  function handleBackdropClick(e: React.MouseEvent<HTMLDialogElement>): void {
    if (e.target === dialogRef.current) close()
  }

  function handleKeyDown(e: React.KeyboardEvent<HTMLDialogElement>): void {
    if (e.key === 'Escape') close()
  }

  return (
    <dialog
      ref={dialogRef}
      className={styles.dialog}
      onClose={close}
      onClick={handleBackdropClick}
      onKeyDown={handleKeyDown}
    >
      <header className={styles.head}>
        <span className={styles.title}>Monitoring the Situation</span>
        <button
          type="button"
          className={styles.close}
          onClick={close}
          aria-label="Close"
        >
          <FiX aria-hidden />
        </button>
      </header>
      <div className={styles.body}>
        <p>
          "Monitoring the situation" is a Twitter/X meme from June 2025. This is
          the version that actually monitors the situation.
        </p>
        <p>
          Operator-grade real-time dashboard pulling live data from ten
          high-signal feeds: DShield mass-scan, Cloudflare Radar BGP/outage, NVD +
          EPSS CVE velocity, CISA KEV, ransomware.live, Coinbase BTC/ETH ticks,
          USGS earthquakes, NOAA SWPC space weather, Wikipedia ITN + GDELT theme
          spikes, and the ISS live position. Single Go binary backend, React 19
          frontend, Postgres + Redis, served behind a Cloudflare Tunnel.
        </p>
        <p>
          <span className={styles.kbd}>F</span> enters presentation mode (full
          viewport, chrome hidden). <span className={styles.kbd}>Esc</span> exits
          or closes this dialog.
        </p>
      </div>
    </dialog>
  )
}

About.displayName = 'About'
