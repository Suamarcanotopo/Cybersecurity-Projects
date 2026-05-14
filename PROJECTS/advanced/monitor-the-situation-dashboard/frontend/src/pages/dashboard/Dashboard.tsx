// ©AngelaMos | 2026
// Dashboard.tsx

import { Globe } from '@/pages/globe/Globe'
import { BGPHijackPanel } from '@/pages/panels/BGPHijackPanel'
import { BTCPanel } from '@/pages/panels/BTCPanel'
import { CVEVelocityPanel } from '@/pages/panels/CVEVelocityPanel'
import { DShieldPanel } from '@/pages/panels/DShieldPanel'
import { EarthquakePanel } from '@/pages/panels/EarthquakePanel'
import { ETHPanel } from '@/pages/panels/ETHPanel'
import { ISSPanel } from '@/pages/panels/ISSPanel'
import { KEVPanel } from '@/pages/panels/KEVPanel'
import { OutagePanel } from '@/pages/panels/OutagePanel'
import { RansomwarePanel } from '@/pages/panels/RansomwarePanel'
import { SpaceWeatherPanel } from '@/pages/panels/SpaceWeatherPanel'
import { WikiPanel } from '@/pages/panels/WikiPanel'
import { useUIStore } from '@/stores/ui'
import { About } from './About'
import { AlertBanner } from './AlertBanner'
import { BottomTicker } from './BottomTicker'
import styles from './Dashboard.module.scss'
import { useDashboardLifecycle } from './lifecycle'
import { presentationMode } from './presentationMode'
import { StatusFooter } from './StatusFooter'
import { TimezoneTickerBar } from './TimezoneTickerBar'
import { TopStrip } from './TopStrip'

export function Dashboard(): React.ReactElement {
  useDashboardLifecycle()
  presentationMode.useGlobalShortcut()
  const isPresentation = useUIStore((s) => s.presentationMode)

  const rootClass = isPresentation
    ? `${styles.root} ${styles.presentation}`
    : styles.root

  return (
    <div className={rootClass}>
      <div className={styles.rotateBanner} aria-hidden="true">
        ↻ Rotate for a better view
      </div>
      <TopStrip />
      <AlertBanner />
      <TimezoneTickerBar />
      <main className={styles.grid}>
        <aside className={styles.left}>
          <div className={styles.group}>
            <BTCPanel />
            <ETHPanel />
          </div>
          <div className={styles.group}>
            <SpaceWeatherPanel />
            <ISSPanel />
            <EarthquakePanel />
          </div>
          <div className={styles.group}>
            <CVEVelocityPanel />
            <WikiPanel />
          </div>
        </aside>
        <section className={styles.center}>
          <Globe />
        </section>
        <aside className={styles.right}>
          <div className={styles.group}>
            <BGPHijackPanel />
            <OutagePanel />
          </div>
          <div className={styles.group}>
            <KEVPanel />
            <RansomwarePanel />
          </div>
          <div className={styles.group}>
            <DShieldPanel />
          </div>
        </aside>
      </main>
      <BottomTicker />
      <StatusFooter />
      <About />
    </div>
  )
}

Dashboard.displayName = 'Dashboard'
