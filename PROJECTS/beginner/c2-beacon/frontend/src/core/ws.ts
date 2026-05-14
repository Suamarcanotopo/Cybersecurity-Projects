// ===================
// © AngelaMos | 2026
// ws.ts
//
// Zustand store and WebSocket hook for the live operator C2 connection
//
// useC2Store holds all live beacon state: beacon map, task results, and
// local-to-server task ID mapping. useOperatorSocket manages the
// /ws/operator WebSocket, dispatches incoming server messages into the
// store, and reconnects with exponential backoff on disconnect.
// sendTask sends a submit_task message to the server.
//
// Key exports:
//   useC2Store - Zustand store for all C2 state and actions
//   useOperatorSocket - hook that owns the WebSocket lifecycle
//   useBeacons, useBeacon, useTaskResults, useTaskIdMap, useIsConnected - selectors
//
// Connects to:
//   config.ts - reads WS_ENDPOINTS.OPERATOR
//   core/types.ts - imports BeaconRecord, TaskResult, parseServerMessage
//   pages/dashboard/index.tsx - calls useBeacons, useIsConnected, useOperatorSocket
//   pages/session/index.tsx - calls useBeacon, useOperatorSocket, useTaskResults, useTaskIdMap
// ===================

import { useEffect, useRef } from 'react'
import { toast } from 'sonner'
import { create } from 'zustand'
import { devtools } from 'zustand/middleware'
import { useShallow } from 'zustand/react/shallow'
import { WS_ENDPOINTS } from '@/config'
import type { BeaconRecord, CommandType, TaskResult } from './types'
import { parseServerMessage } from './types'

interface C2State {
  beacons: Record<string, BeaconRecord>
  taskResults: TaskResult[]
  taskIdMap: Record<string, string>
  connected: boolean
}

interface C2Actions {
  setBeacons: (list: BeaconRecord[]) => void
  upsertBeacon: (
    beacon: Omit<BeaconRecord, 'active' | 'first_seen' | 'last_seen'>
  ) => void
  markDisconnected: (id: string) => void
  markHeartbeat: (id: string) => void
  addTaskResult: (result: TaskResult) => void
  mapTaskId: (localId: string, taskId: string) => void
  setConnected: (connected: boolean) => void
  clearResults: () => void
}

type C2Store = C2State & C2Actions

export const useC2Store = create<C2Store>()(
  devtools(
    (set) => ({
      beacons: {},
      taskResults: [],
      taskIdMap: {},
      connected: false,

      setBeacons: (list) =>
        set(
          () => {
            const beacons: Record<string, BeaconRecord> = {}
            for (const b of list) {
              beacons[b.id] = b
            }
            return { beacons }
          },
          false,
          'c2/setBeacons'
        ),

      upsertBeacon: (beacon) =>
        set(
          (state) => {
            const existing = state.beacons[beacon.id]
            return {
              beacons: {
                ...state.beacons,
                [beacon.id]: {
                  ...beacon,
                  active: true,
                  first_seen: existing?.first_seen ?? new Date().toISOString(),
                  last_seen: new Date().toISOString(),
                },
              },
            }
          },
          false,
          'c2/upsertBeacon'
        ),

      markDisconnected: (id) =>
        set(
          (state) => {
            const beacon = state.beacons[id]
            if (!beacon) return state
            return {
              beacons: { ...state.beacons, [id]: { ...beacon, active: false } },
            }
          },
          false,
          'c2/markDisconnected'
        ),

      markHeartbeat: (id) =>
        set(
          (state) => {
            const beacon = state.beacons[id]
            if (!beacon) return state
            return {
              beacons: {
                ...state.beacons,
                [id]: {
                  ...beacon,
                  active: true,
                  last_seen: new Date().toISOString(),
                },
              },
            }
          },
          false,
          'c2/markHeartbeat'
        ),

      addTaskResult: (result) =>
        set(
          (state) => ({
            taskResults: [...state.taskResults, result],
          }),
          false,
          'c2/addTaskResult'
        ),

      mapTaskId: (localId, taskId) =>
        set(
          (state) => ({
            taskIdMap: { ...state.taskIdMap, [localId]: taskId },
          }),
          false,
          'c2/mapTaskId'
        ),

      setConnected: (connected) => set({ connected }, false, 'c2/setConnected'),

      clearResults: () => set({ taskResults: [] }, false, 'c2/clearResults'),
    }),
    { name: 'C2Store' }
  )
)

function getWsUrl(): string {
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
  return `${protocol}//${window.location.host}${WS_ENDPOINTS.OPERATOR}`
}

export function useOperatorSocket(): {
  sendTask: (
    beaconId: string,
    command: CommandType,
    args?: string,
    localId?: string
  ) => void
} {
  const wsRef = useRef<WebSocket | null>(null)
  const reconnectTimer = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(() => {
    const {
      setBeacons,
      upsertBeacon,
      markDisconnected,
      markHeartbeat,
      addTaskResult,
      mapTaskId,
      setConnected,
    } = useC2Store.getState()

    let attempt = 0

    function connect(): void {
      const ws = new WebSocket(getWsUrl())
      wsRef.current = ws

      ws.onopen = () => {
        attempt = 0
        setConnected(true)
      }

      ws.onmessage = (event) => {
        const message = parseServerMessage(event.data as string)
        if (message === null) return

        switch (message.type) {
          case 'beacon_list':
            setBeacons(message.payload)
            break
          case 'beacon_connected':
            upsertBeacon(message.payload)
            toast.success(`Beacon connected: ${message.payload.hostname}`)
            break
          case 'beacon_disconnected':
            markDisconnected(message.payload.id)
            break
          case 'heartbeat':
            markHeartbeat(message.payload.id)
            break
          case 'task_result':
            addTaskResult(message.payload)
            break
          case 'task_submitted':
            mapTaskId(message.payload.local_id, message.payload.task_id)
            break
        }
      }

      ws.onclose = () => {
        setConnected(false)
        const delay = Math.min(1000 * 2 ** attempt, 30000)
        attempt += 1
        reconnectTimer.current = setTimeout(connect, delay) as ReturnType<
          typeof setTimeout
        >
      }

      ws.onerror = () => {
        ws.close()
      }
    }

    connect()

    return () => {
      if (reconnectTimer.current !== null) {
        clearTimeout(reconnectTimer.current)
      }
      wsRef.current?.close()
    }
  }, [])

  function sendTask(
    beaconId: string,
    command: CommandType,
    args?: string,
    localId?: string
  ): void {
    const ws = wsRef.current
    if (ws === null || ws.readyState !== WebSocket.OPEN) return

    ws.send(
      JSON.stringify({
        type: 'submit_task',
        payload: {
          beacon_id: beaconId,
          command,
          args: args ?? null,
          local_id: localId ?? null,
        },
      })
    )
  }

  return { sendTask }
}

export const useBeacons = (): BeaconRecord[] =>
  useC2Store(useShallow((s) => Object.values(s.beacons)))

export const useBeacon = (id: string): BeaconRecord | undefined =>
  useC2Store((s) => s.beacons[id])

export const useTaskResults = (): TaskResult[] => useC2Store((s) => s.taskResults)

export const useTaskIdMap = (): Record<string, string> =>
  useC2Store((s) => s.taskIdMap)

export const useIsConnected = (): boolean => useC2Store((s) => s.connected)
