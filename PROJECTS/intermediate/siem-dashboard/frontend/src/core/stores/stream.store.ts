// ===================
// ©AngelaMos | 2026
// stream.store.ts
//
// Zustand store for real-time SSE event buffers
//
// Maintains in-memory ring buffers (max 500 entries each) for log and alert
// events arriving over Server-Sent Events. Tracks connection status for both
// streams separately. Not persisted to localStorage since the data is
// transient. Events are prepended so the newest entry is always first.
//
// Key exports:
//   useStreamStore - Zustand store hook with push, clear, and status actions
//
// Connects to:
//   useEventStream.ts - calls pushLogEvent, pushAlertEvent, setLogConnected, setAlertConnected
// ===================

import { create } from 'zustand'
import { devtools } from 'zustand/middleware'

const MAX_BUFFER_SIZE = 500

interface StreamEvent {
  id: string
  timestamp: string
  data: Record<string, unknown>
}

interface StreamState {
  logEvents: StreamEvent[]
  alertEvents: StreamEvent[]
  logConnected: boolean
  alertConnected: boolean
  pushLogEvent: (event: StreamEvent) => void
  pushAlertEvent: (event: StreamEvent) => void
  setLogConnected: (connected: boolean) => void
  setAlertConnected: (connected: boolean) => void
  clearLogs: () => void
  clearAlerts: () => void
}

export const useStreamStore = create<StreamState>()(
  devtools(
    (set) => ({
      logEvents: [],
      alertEvents: [],
      logConnected: false,
      alertConnected: false,

      pushLogEvent: (event) =>
        set(
          (state) => ({
            logEvents: [event, ...state.logEvents].slice(0, MAX_BUFFER_SIZE),
          }),
          false,
          'stream/pushLog'
        ),

      pushAlertEvent: (event) =>
        set(
          (state) => ({
            alertEvents: [event, ...state.alertEvents].slice(0, MAX_BUFFER_SIZE),
          }),
          false,
          'stream/pushAlert'
        ),

      setLogConnected: (connected) =>
        set({ logConnected: connected }, false, 'stream/logConnected'),

      setAlertConnected: (connected) =>
        set({ alertConnected: connected }, false, 'stream/alertConnected'),

      clearLogs: () => set({ logEvents: [] }, false, 'stream/clearLogs'),

      clearAlerts: () => set({ alertEvents: [] }, false, 'stream/clearAlerts'),
    }),
    { name: 'StreamStore' }
  )
)
