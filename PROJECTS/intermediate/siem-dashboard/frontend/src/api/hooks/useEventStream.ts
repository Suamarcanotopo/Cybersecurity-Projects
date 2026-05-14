// ===================
// ©AngelaMos | 2026
// useEventStream.ts
//
// SSE hooks that connect to the live log and alert streams
//
// useLogStream and useAlertStream each open an EventSource connection to the
// backend. Because EventSource doesn't support custom headers, the JWT is
// passed as a URL query parameter. On error the connection closes and
// reconnects after 3 seconds. Events are pushed into the stream store's
// ring buffers. Both hooks clean up their connection on unmount.
//
// Key exports:
//   useLogStream - connects to /logs/stream and pushes events into streamStore
//   useAlertStream - connects to /alerts/stream and pushes events into streamStore
//
// Connects to:
//   stream.store.ts - pushLogEvent, pushAlertEvent, setLogConnected, setAlertConnected
//   auth.store.ts - reads accessToken for the URL query param
//   api.ts - getBaseURL() for SSE URL construction
// ===================

import { useCallback, useEffect, useRef } from 'react'
import type { StreamAlertEvent, StreamLogEvent } from '@/api/types'
import { API_ENDPOINTS } from '@/config'
import { getBaseURL } from '@/core/lib'
import { useAuthStore, useStreamStore } from '@/core/stores'

const SSE_RECONNECT_DELAY = 3000

export function useLogStream(): void {
  const token = useAuthStore((s) => s.accessToken)
  const setLogConnected = useStreamStore((s) => s.setLogConnected)
  const pushLogEvent = useStreamStore((s) => s.pushLogEvent)
  const sourceRef = useRef<EventSource | null>(null)

  const connect = useCallback(() => {
    if (token === null) return

    const url = `${getBaseURL()}${API_ENDPOINTS.LOGS.STREAM}?token=${encodeURIComponent(token)}`
    const source = new EventSource(url)
    sourceRef.current = source

    source.onopen = () => setLogConnected(true)

    source.addEventListener('log', (event: MessageEvent<string>) => {
      const data = JSON.parse(event.data) as StreamLogEvent
      pushLogEvent({ id: data.id, timestamp: data.timestamp, data })
    })

    source.onerror = () => {
      setLogConnected(false)
      source.close()
      sourceRef.current = null
      setTimeout(connect, SSE_RECONNECT_DELAY)
    }
  }, [token, setLogConnected, pushLogEvent])

  useEffect(() => {
    connect()
    return () => {
      sourceRef.current?.close()
      sourceRef.current = null
      setLogConnected(false)
    }
  }, [connect, setLogConnected])
}

export function useAlertStream(): void {
  const token = useAuthStore((s) => s.accessToken)
  const setAlertConnected = useStreamStore((s) => s.setAlertConnected)
  const pushAlertEvent = useStreamStore((s) => s.pushAlertEvent)
  const sourceRef = useRef<EventSource | null>(null)

  const connect = useCallback(() => {
    if (token === null) return

    const url = `${getBaseURL()}${API_ENDPOINTS.ALERTS.STREAM}?token=${encodeURIComponent(token)}`
    const source = new EventSource(url)
    sourceRef.current = source

    source.onopen = () => setAlertConnected(true)

    source.addEventListener('alert', (event: MessageEvent<string>) => {
      const data = JSON.parse(event.data) as StreamAlertEvent
      pushAlertEvent({
        id: data.id,
        timestamp: new Date().toISOString(),
        data,
      })
    })

    source.onerror = () => {
      setAlertConnected(false)
      source.close()
      sourceRef.current = null
      setTimeout(connect, SSE_RECONNECT_DELAY)
    }
  }, [token, setAlertConnected, pushAlertEvent])

  useEffect(() => {
    connect()
    return () => {
      sourceRef.current?.close()
      sourceRef.current = null
      setAlertConnected(false)
    }
  }, [connect, setAlertConnected])
}
