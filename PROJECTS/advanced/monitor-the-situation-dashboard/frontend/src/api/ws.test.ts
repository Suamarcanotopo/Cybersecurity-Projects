// ©AngelaMos | 2026
// ws.test.ts

import { describe, expect, it, vi } from 'vitest'
import { createDashboardWS, type WSDriver } from './ws'

class FakeDriver implements WSDriver {
  onOpen: (() => void) | null = null
  onMessage: ((data: string) => void) | null = null
  onClose: (() => void) | null = null
  sent: string[] = []
  closed = false

  send(s: string) {
    this.sent.push(s)
  }

  close() {
    if (this.closed) return
    this.closed = true
    this.onClose?.()
  }

  fire(data: string) {
    this.onMessage?.(data)
  }

  open() {
    this.onOpen?.()
  }
}

describe('dashboard WS', () => {
  it('does not send init until setReady() is called', () => {
    const drv = new FakeDriver()
    const ws = createDashboardWS({
      driver: () => drv,
      topics: ['heartbeat'],
    })
    ws.connect()
    drv.open()
    expect(drv.sent).toEqual([])
    ws.setReady()
    expect(drv.sent).toContain('{"op":"init"}')
    ws.disconnect()
  })

  it('buffers events received before ready, replays on setReady', () => {
    const drv = new FakeDriver()
    const events: unknown[] = []
    const ws = createDashboardWS({
      driver: () => drv,
      topics: ['heartbeat'],
      onEvent: (e) => events.push(e),
    })
    ws.connect()
    drv.open()
    drv.fire(JSON.stringify({ topic: 'heartbeat', payload: {} }))
    expect(events).toHaveLength(0)
    ws.setReady()
    expect(events).toHaveLength(1)
    ws.disconnect()
  })

  it('forwards events received after ready immediately', () => {
    const drv = new FakeDriver()
    const events: unknown[] = []
    const ws = createDashboardWS({
      driver: () => drv,
      topics: ['heartbeat'],
      onEvent: (e) => events.push(e),
    })
    ws.connect()
    drv.open()
    ws.setReady()
    drv.fire(JSON.stringify({ topic: 'heartbeat', payload: { v: 1 } }))
    expect(events).toHaveLength(1)
    ws.disconnect()
  })

  it('reconnects with backoff after drop and resends init when ready', async () => {
    const drivers: FakeDriver[] = []
    const ws = createDashboardWS({
      driver: () => {
        const d = new FakeDriver()
        drivers.push(d)
        return d
      },
      topics: ['heartbeat'],
      backoff: { initialMs: 5, maxMs: 20 },
    })
    ws.connect()
    drivers[0].open()
    ws.setReady()
    expect(drivers[0].sent).toContain('{"op":"init"}')

    drivers[0].close()
    await new Promise((r) => setTimeout(r, 50))

    expect(drivers.length).toBeGreaterThanOrEqual(2)
    drivers[1].open()
    expect(drivers[1].sent).toContain('{"op":"init"}')
    ws.disconnect()
  })

  it('does not reconnect after explicit disconnect', async () => {
    const drivers: FakeDriver[] = []
    const ws = createDashboardWS({
      driver: () => {
        const d = new FakeDriver()
        drivers.push(d)
        return d
      },
      topics: ['heartbeat'],
      backoff: { initialMs: 5, maxMs: 20 },
    })
    ws.connect()
    drivers[0].open()
    ws.disconnect()
    await new Promise((r) => setTimeout(r, 30))
    expect(drivers).toHaveLength(1)
  })

  it('ignores malformed JSON without crashing', () => {
    const drv = new FakeDriver()
    const events: unknown[] = []
    const errors = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const ws = createDashboardWS({
      driver: () => drv,
      topics: ['heartbeat'],
      onEvent: (e) => events.push(e),
    })
    ws.connect()
    drv.open()
    ws.setReady()
    drv.fire('{not json')
    expect(events).toHaveLength(0)
    errors.mockRestore()
    ws.disconnect()
  })
})
