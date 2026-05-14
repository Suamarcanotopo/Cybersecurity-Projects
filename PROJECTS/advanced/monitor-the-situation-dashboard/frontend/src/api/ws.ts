// ©AngelaMos | 2026
// ws.ts

export interface WSDriver {
  onOpen: (() => void) | null
  onMessage: ((data: string) => void) | null
  onClose: (() => void) | null
  send(s: string): void
  close(): void
}

export interface WSEvent {
  ch: string
  data?: unknown
  ts?: string
}

export interface BackoffConfig {
  initialMs: number
  maxMs: number
}

export interface CreateDashboardWSOpts {
  driver: () => WSDriver
  topics: string[]
  onEvent?: (ev: WSEvent) => void
  backoff?: BackoffConfig
}

const DEFAULT_BACKOFF: BackoffConfig = {
  initialMs: 1_000,
  maxMs: 30_000,
}

interface DashboardWS {
  connect: () => void
  setReady: () => void
  disconnect: () => void
}

const INIT_OP = '{"op":"init"}'

export function createDashboardWS(opts: CreateDashboardWSOpts): DashboardWS {
  const backoff = opts.backoff ?? DEFAULT_BACKOFF
  const onEvent = opts.onEvent ?? (() => undefined)

  let driver: WSDriver | null = null
  let ready = false
  let opened = false
  let closed = false
  let buffer: WSEvent[] = []
  let nextDelay = backoff.initialMs
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null

  function sendInitIfReady() {
    if (ready && opened && driver) {
      driver.send(INIT_OP)
    }
  }

  function attach() {
    if (closed) return
    const d = opts.driver()
    driver = d
    opened = false
    d.onOpen = () => {
      nextDelay = backoff.initialMs
      opened = true
      sendInitIfReady()
    }
    d.onMessage = (data) => {
      let parsed: WSEvent
      try {
        parsed = JSON.parse(data) as WSEvent
      } catch {
        return
      }
      if (ready) {
        onEvent(parsed)
      } else {
        buffer.push(parsed)
      }
    }
    d.onClose = () => {
      driver = null
      opened = false
      if (closed) return
      const delay = nextDelay
      nextDelay = Math.min(nextDelay * 2, backoff.maxMs)
      reconnectTimer = setTimeout(attach, delay)
    }
  }

  return {
    connect() {
      attach()
    },
    setReady() {
      ready = true
      sendInitIfReady()
      const flush = buffer
      buffer = []
      for (const ev of flush) onEvent(ev)
    },
    disconnect() {
      closed = true
      ready = false
      opened = false
      if (reconnectTimer) {
        clearTimeout(reconnectTimer)
        reconnectTimer = null
      }
      driver?.close()
      driver = null
      buffer = []
    },
  }
}

export function browserDriver(url: string, topics: string[]): WSDriver {
  const u = new URL(url, window.location.origin.replace('http', 'ws'))
  if (topics.length > 0) u.searchParams.set('topics', topics.join(','))
  const sock = new WebSocket(u.toString())

  const driver: WSDriver = {
    onOpen: null,
    onMessage: null,
    onClose: null,
    send(s) {
      if (sock.readyState === WebSocket.OPEN) sock.send(s)
    },
    close() {
      sock.close()
    },
  }
  sock.addEventListener('open', () => driver.onOpen?.())
  sock.addEventListener('message', (e) => driver.onMessage?.(String(e.data)))
  sock.addEventListener('close', () => driver.onClose?.())
  return driver
}
