// ===================
// ©AngelaMos | 2026
// index.tsx
//
// Public landing page describing the SIEM dashboard's four main capabilities
//
// Renders a static marketing page with feature sections for real-time
// monitoring, attack scenarios, the correlation engine, and alert triage.
// Links to the login and register routes. No authentication required.
//
// Key components:
//   Component - lazy-loaded landing page; displayName "Landing"
//
// Connects to:
//   config.ts - ROUTES.LOGIN, ROUTES.REGISTER for navigation links
// ===================

import { GiDualityMask, GiHumanTarget } from 'react-icons/gi'
import { GoAlert } from 'react-icons/go'
import { LuActivity } from 'react-icons/lu'
import { Link } from 'react-router-dom'
import { ROUTES } from '@/config'
import styles from './landing.module.scss'

export function Component(): React.ReactElement {
  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <h1 className={styles.title}>SIEM Dashboard</h1>
        <p className={styles.subtitle}>
          Security monitoring and attack simulation
        </p>
      </header>

      <div className={styles.content}>
        <p className={styles.description}>
          A fully functional Security Information and Event Management system.
          Launch simulated attack scenarios, watch log events flow through a
          correlation engine in real time, and triage the alerts it generates.
        </p>

        <div className={styles.sections}>
          <section className={styles.section}>
            <div className={styles.sectionIcon}>
              <LuActivity />
            </div>
            <h2 className={styles.sectionTitle}>Real-Time Monitoring</h2>
            <p className={styles.sectionText}>
              Live event timeline, streaming log viewer, and dashboard analytics
              powered by MongoDB aggregation pipelines and Server-Sent Events.
            </p>
          </section>

          <section className={styles.section}>
            <div className={styles.sectionIcon}>
              <GiHumanTarget />
            </div>
            <h2 className={styles.sectionTitle}>Attack Scenarios</h2>
            <p className={styles.sectionText}>
              YAML-defined playbooks simulating brute force, phishing C2,
              privilege escalation, and data exfiltration — all mapped to MITRE
              ATT&CK techniques.
            </p>
          </section>

          <section className={styles.section}>
            <div className={styles.sectionIcon}>
              <GiDualityMask />
            </div>
            <h2 className={styles.sectionTitle}>Correlation Engine</h2>
            <p className={styles.sectionText}>
              Threshold, sequence, and aggregation rules evaluate every event in
              real time via Redis Streams, automatically generating alerts when
              attack patterns are detected.
            </p>
          </section>

          <section className={styles.section}>
            <div className={styles.sectionIcon}>
              <GoAlert />
            </div>
            <h2 className={styles.sectionTitle}>Alert Triage</h2>
            <p className={styles.sectionText}>
              Review, acknowledge, investigate, and resolve alerts. Pivot from an
              alert to matched log events by source IP, username, or hostname for
              forensic analysis.
            </p>
          </section>
        </div>

        <div className={styles.actions}>
          <Link to={ROUTES.LOGIN} className={styles.button}>
            Login
          </Link>
          <Link to={ROUTES.REGISTER} className={styles.buttonOutline}>
            Create Account
          </Link>
        </div>
      </div>
    </div>
  )
}

Component.displayName = 'Landing'
