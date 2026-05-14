// ©AngelaMos | 2026
// lifecycle.ts

import { type QueryClient, useQueryClient } from '@tanstack/react-query'
import { useEffect, useRef } from 'react'
import { SNAPSHOT_KEY, type Snapshot, useSnapshot } from '@/api/snapshot'
import {
  type BgpHijack,
  type CveEvent,
  type DShieldData,
  type EarthquakePayload,
  type GdeltSpike,
  type InternetOutage,
  type IssPosition,
  isValidBgpHijack,
  isValidCoinbaseTick,
  isValidCveEvent,
  isValidDShieldData,
  isValidEarthquakePayload,
  isValidGdeltSpike,
  isValidInternetOutage,
  isValidIssPosition,
  isValidKevEntry,
  isValidRansomwareVictim,
  isValidWikiItn,
  type KevEntry,
  type RansomwareVictim,
  type WikiItn,
} from '@/api/types'
import { browserDriver, createDashboardWS, type WSEvent } from '@/api/ws'
import { unlockOnFirstGesture } from '@/lib/audio'
import { getCentroid } from '@/lib/countryCentroids'
import { useBgpHijackStore } from '@/stores/bgpHijack'
import { useCveStore } from '@/stores/cve'
import { useEarthquakeStore } from '@/stores/earthquake'
import { type SourceKey, useFreshness } from '@/stores/freshness'
import { useGlobeEvents } from '@/stores/globeEvents'
import { useHeartbeat } from '@/stores/heartbeat'
import { useKevStore } from '@/stores/kev'
import { useOutageStore } from '@/stores/outage'
import { usePrices } from '@/stores/prices'
import { useRansomwareStore, victimKey } from '@/stores/ransomware'
import { useTicker } from '@/stores/ticker'

const ALL_TOPICS: readonly string[] = [
  'heartbeat',
  'scan_firehose',
  'internet_outage',
  'bgp_hijack',
  'cve_new',
  'kev_added',
  'ransomware_victim',
  'coinbase_price',
  'earthquake',
  'space_weather',
  'wiki_itn',
  'gdelt_spike',
  'iss_position',
]

const WS_URL = '/api/v1/ws'
const GLOBE_RING_TTL_MS = 4_000
const GLOBE_EVICT_INTERVAL_MS = 5 * 60_000

export function useDashboardLifecycle(): void {
  const { data: snapshot, isSuccess } = useSnapshot()
  const queryClient = useQueryClient()
  const wsRef = useRef<ReturnType<typeof createDashboardWS> | null>(null)
  const globeSeededRef = useRef(false)

  useEffect(() => {
    unlockOnFirstGesture()
  }, [])

  useEffect(() => {
    if (!snapshot || globeSeededRef.current) return
    globeSeededRef.current = true
    seedGlobeFromSnapshot(snapshot)
  }, [snapshot])

  useEffect(() => {
    if (!isSuccess) return

    const ws = createDashboardWS({
      driver: () => browserDriver(WS_URL, [...ALL_TOPICS]),
      topics: [...ALL_TOPICS],
      onEvent: (ev) => routeEvent(ev, queryClient),
    })
    wsRef.current = ws
    ws.connect()
    ws.setReady()

    return () => {
      ws.disconnect()
      wsRef.current = null
    }
  }, [isSuccess, queryClient])

  useEffect(() => {
    const id = setInterval(() => {
      useGlobeEvents.getState().evict(Date.now())
    }, GLOBE_EVICT_INTERVAL_MS)
    return () => clearInterval(id)
  }, [])

  void snapshot
}

function routeEvent(ev: WSEvent, queryClient: QueryClient): void {
  if (ev.ch === 'heartbeat') {
    useHeartbeat.getState().beat()
    useFreshness.getState().ping('ws')
    return
  }
  const data = ev.data
  if (data === undefined || data === null) return
  dispatchEvent(ev.ch, data, queryClient)
}

function dispatchEvent(
  ch: string,
  data: unknown,
  queryClient: QueryClient
): void {
  const ping = useFreshness.getState().ping
  switch (ch) {
    case 'cve_new':
      if (isValidCveEvent(data)) {
        handleCve(data)
        ping('cve')
      }
      break
    case 'kev_added':
      if (isValidKevEntry(data)) {
        handleKev(data)
        ping('kev')
      }
      break
    case 'ransomware_victim':
      if (isValidRansomwareVictim(data)) {
        handleRansomware(data)
        ping('ransomware')
      }
      break
    case 'coinbase_price':
      if (isValidCoinbaseTick(data)) {
        handleCoinbase(data)
        pingCoinbaseChannel(data.symbol, ping)
      }
      break
    case 'earthquake':
      if (isValidEarthquakePayload(data)) {
        handleEarthquake(data)
        ping('quake')
      }
      break
    case 'iss_position':
      if (isValidIssPosition(data)) {
        handleIss(data, queryClient)
        ping('iss')
      }
      break
    case 'wiki_itn':
      if (isValidWikiItn(data)) {
        handleWiki(data)
        ping('wiki')
      }
      break
    case 'gdelt_spike':
      if (isValidGdeltSpike(data)) handleGdelt(data)
      break
    case 'internet_outage':
      if (isValidInternetOutage(data)) {
        handleOutage(data, queryClient)
        ping('outage')
      }
      break
    case 'bgp_hijack':
      if (isValidBgpHijack(data)) {
        handleHijack(data, queryClient)
        ping('bgp')
      }
      break
    case 'scan_firehose':
      if (isValidDShieldData(data)) {
        handleScanFirehose(data, queryClient)
        ping('dshield')
      }
      break
    case 'space_weather':
      mergeIntoSnapshot(queryClient, ch, data)
      ping('spacewx')
      break
    default:
      break
  }
}

function pingCoinbaseChannel(symbol: string, ping: (k: SourceKey) => void): void {
  if (symbol === 'BTC-USD') ping('btc')
  else if (symbol === 'ETH-USD') ping('eth')
}

function handleCve(p: CveEvent): void {
  useCveStore.getState().push(p)
  useTicker.getState().push({
    id: `cve-tick-${p.CveID}`,
    source: 'CVE',
    headline: `${p.CveID} · ${p.Severity}`,
    ts: Date.now(),
  })
}

function handleKev(p: KevEntry): void {
  useKevStore.getState().push(p)
}

function handleRansomware(p: RansomwareVictim): void {
  useRansomwareStore.getState().push(p)
  pushRansomwarePoint(p)
  useTicker.getState().push({
    id: `rw-tick-${victimKey(p)}`,
    source: 'RANSOM',
    headline: `${p.group_name} · ${p.post_title}`,
    ts: Date.now(),
  })
}

function pushRansomwarePoint(p: RansomwareVictim): void {
  if (!p.country) return
  const c = getCentroid(p.country)
  if (!c) return
  useGlobeEvents.getState().pushPoint({
    id: `rw-${victimKey(p)}`,
    type: 'ransomware',
    lat: c.lat,
    lng: c.lng,
    emittedAt: Date.now(),
    meta: { group_name: p.group_name, post_title: p.post_title },
  })
}

function handleOutage(p: InternetOutage, queryClient: QueryClient): void {
  useOutageStore.getState().push(p)
  pushOutagePoints(p)
  mergeIntoSnapshot(queryClient, 'internet_outage', p)
}

function pushOutagePoints(p: InternetOutage): void {
  if (!Array.isArray(p.locations)) return
  const now = Date.now()
  for (const loc of p.locations) {
    const c = getCentroid(loc)
    if (!c) continue
    useGlobeEvents.getState().pushPoint({
      id: `outage-${p.id}-${loc}`,
      type: 'outage',
      lat: c.lat,
      lng: c.lng,
      emittedAt: now,
      meta: { reason: p.reason, type: p.outageType },
    })
  }
}

function handleHijack(p: BgpHijack, queryClient: QueryClient): void {
  useBgpHijackStore.getState().push(p)
  pushHijackPoint(p)
  mergeIntoSnapshot(queryClient, 'bgp_hijack', p)
  const n = p.prefixes?.length ?? 0
  useTicker.getState().push({
    id: `bgp-tick-${p.id}`,
    source: 'BGP',
    headline: `ASN ${p.hijackerAsn || '?'} · ${n} prefix${n !== 1 ? 'es' : ''} hijacked`,
    ts: Date.now(),
  })
}

function pushHijackPoint(p: BgpHijack): void {
  const country = p.enrichment?.country
  if (!country) return
  const c = getCentroid(country)
  if (!c) return
  useGlobeEvents.getState().pushPoint({
    id: `hijack-${p.id}`,
    type: 'hijack',
    lat: c.lat,
    lng: c.lng,
    emittedAt: Date.now(),
    meta: {
      asn: p.hijackerAsn,
      isp: p.enrichment?.isp,
      prefixes: p.prefixes?.length,
    },
  })
}

function handleScanFirehose(p: DShieldData, queryClient: QueryClient): void {
  pushScanPoints(p)
  mergeIntoSnapshot(queryClient, 'scan_firehose', p)
}

function pushScanPoints(p: DShieldData): void {
  const now = Date.now()
  for (const src of p.topips ?? []) {
    if (!src.country) continue
    const c = getCentroid(src.country)
    if (!c) continue
    useGlobeEvents.getState().pushPoint({
      id: `scan-${src.source}`,
      type: 'scan',
      lat: c.lat,
      lng: c.lng,
      emittedAt: now,
      meta: { source: src.source, reports: src.reports },
    })
  }
}

function handleCoinbase(p: {
  symbol: string
  ts: string
  price: string
  volume_24h?: string
}): void {
  const tsMs = new Date(p.ts).getTime()
  const minute = Math.floor(tsMs / 60_000) * 60_000
  const prices = usePrices.getState()

  prices.pushTick({
    symbol: p.symbol,
    ts: tsMs,
    price: p.price,
    volume24h: p.volume_24h,
  })

  const bars = prices.history[p.symbol] ?? []
  const existing = bars.find((b) => b.minute === minute)
  const num = Number(p.price)

  prices.pushMinute({
    symbol: p.symbol,
    minute,
    open: existing?.open ?? p.price,
    high: existing ? String(Math.max(Number(existing.high), num)) : p.price,
    low: existing ? String(Math.min(Number(existing.low), num)) : p.price,
    close: p.price,
    volume: p.volume_24h,
  })
}

function handleEarthquake(p: EarthquakePayload): void {
  useEarthquakeStore.getState().push(p)
  const coords = p.geometry?.coordinates
  if (!Array.isArray(coords)) return
  const lng = coords[0]
  const lat = coords[1]
  if (typeof lat !== 'number' || typeof lng !== 'number') return
  const now = Date.now()
  useGlobeEvents.getState().pushPoint({
    id: `eq-${p.id}`,
    type: 'earthquake',
    lat,
    lng,
    emittedAt: now,
    meta: p.properties,
  })
  useGlobeEvents.getState().pushRing({
    id: `eq-ring-${p.id}-${now}`,
    lat,
    lng,
    emittedAt: now,
    ttlMs: GLOBE_RING_TTL_MS,
  })
}

function handleIss(p: IssPosition, queryClient: QueryClient): void {
  useGlobeEvents.getState().pushPoint({
    id: 'iss-current',
    type: 'iss',
    lat: p.latitude,
    lng: p.longitude,
    emittedAt: Date.now(),
  })
  mergeIntoSnapshot(queryClient, 'iss_position', p)
}

function handleWiki(p: WikiItn): void {
  if (!p.text) return
  const id = `wiki-${p.slug || p.text}`
  useTicker.getState().push({
    id,
    source: 'Wikipedia',
    headline: p.text,
    ts: Date.now(),
    href: p.slug ? `https://en.wikipedia.org/wiki/${p.slug}` : undefined,
  })
}

function handleGdelt(p: GdeltSpike): void {
  useTicker.getState().push({
    id: `gdelt-${p.theme}-${p.time}`,
    source: 'GDELT',
    headline: `${p.theme} spike (z=${p.zscore.toFixed(2)}, n=${p.count})`,
    ts: Date.now(),
  })
}

function mergeIntoSnapshot(
  queryClient: QueryClient,
  topic: string,
  data: unknown
): void {
  queryClient.setQueryData<Record<string, unknown>>(SNAPSHOT_KEY, (prev) => ({
    ...(prev ?? {}),
    [topic]: data,
  }))
}

function seedGlobeFromSnapshot(snap: Snapshot): void {
  const eq = snap.earthquake
  if (isValidEarthquakePayload(eq)) {
    useEarthquakeStore.getState().push(eq)
    const coords = eq.geometry?.coordinates
    if (Array.isArray(coords)) {
      const lng = coords[0]
      const lat = coords[1]
      if (typeof lat === 'number' && typeof lng === 'number') {
        useGlobeEvents.getState().pushPoint({
          id: `eq-${eq.id}`,
          type: 'earthquake',
          lat,
          lng,
          emittedAt: Date.now(),
          meta: eq.properties,
        })
      }
    }
  }

  const iss = snap.iss_position
  if (isValidIssPosition(iss)) {
    useGlobeEvents.getState().pushPoint({
      id: 'iss-current',
      type: 'iss',
      lat: iss.latitude,
      lng: iss.longitude,
      emittedAt: Date.now(),
    })
  }

  const rw = snap.ransomware_victim
  if (isValidRansomwareVictim(rw)) {
    pushRansomwarePoint(rw)
    useTicker.getState().push({
      id: `rw-tick-${victimKey(rw)}`,
      source: 'RANSOM',
      headline: `${rw.group_name} · ${rw.post_title}`,
      ts: Date.now(),
    })
  }

  const outage = snap.internet_outage
  if (isValidInternetOutage(outage)) {
    useOutageStore.getState().push(outage)
    pushOutagePoints(outage)
  }

  const hijack = snap.bgp_hijack
  if (isValidBgpHijack(hijack)) {
    useBgpHijackStore.getState().push(hijack)
    pushHijackPoint(hijack)
    const n = hijack.prefixes?.length ?? 0
    useTicker.getState().push({
      id: `bgp-tick-${hijack.id}`,
      source: 'BGP',
      headline: `ASN ${hijack.hijackerAsn || '?'} · ${n} prefix${n !== 1 ? 'es' : ''} hijacked`,
      ts: Date.now(),
    })
  }

  const scan = snap.scan_firehose
  if (isValidDShieldData(scan)) pushScanPoints(scan)

  const wiki = snap.wiki_itn
  if (isValidWikiItn(wiki) && wiki.text) {
    useTicker.getState().push({
      id: `wiki-${wiki.slug || wiki.text}`,
      source: 'Wikipedia',
      headline: wiki.text,
      ts: Date.now(),
      href: wiki.slug ? `https://en.wikipedia.org/wiki/${wiki.slug}` : undefined,
    })
  }
}
