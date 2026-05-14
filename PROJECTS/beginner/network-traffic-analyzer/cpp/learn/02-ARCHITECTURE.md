# System Architecture

## High-Level Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     main.cpp                                │
│  • arg parsing        • thread coordination                 │
│  • offline vs live    • CSV/JSON export on exit             │
└───────────┬─────────────────────────────┬───────────────────┘
            │                             │
     ┌──────▼──────┐             ┌────────▼────────┐
     │ PcapCapture │             │   FTXUI screen  │
     │ (libpcap)   │             │   (main thread) │
     └──────┬──────┘             └────────▲────────┘
            │ got_packet()                │ PostEvent()
            │                    ┌────────┴────────┐
     ┌──────▼──────┐             │ application_    │
     │  IPv4/IPv6  │             │ thread          │
     │  (parser)   │             │ (UI update loop)│
     └──────┬──────┘             └────────▲────────┘
            │ Packet                      │ get_snapshot()
     ┌──────▼──────────────────────────┐  │
     │           Stats                 │──┘
     │  add_packet()  push()           │
     │  transport_map  application_map │
     │  ip_map  pairs  packets deque   │
     │  bandwidth_history              │
     │  StatsSnapshot (under mutex)    │
     └─────────────────────────────────┘
```

## Threading Model

There are three concurrent execution contexts:

**Capture thread** — spawned by `PcapCapture::start()` at `pcapCapture.cpp:80`. Runs `pcap_loop()` which calls `callback()` → `got_packet()` for each packet. Calls `Stats::add_packet()` and `Stats::push()`. Never touches the UI.

**UI update thread** (`application_thread`, `main.cpp:107`) — runs a loop that:
1. Advances the elapsed timer
2. Checks stop conditions (time limit, capture finished)
3. Calls all `Stats::update_*()` methods to rebuild snapshot tables
4. Calls `view.render(stats.get_snapshot(), ...)` to build a new FTXUI element tree
5. Stores the element in `current_render` under `render_mtx`
6. Posts a `Custom` event to the FTXUI screen to trigger a repaint

**FTXUI event loop** — runs on the main thread via `screen.Loop(component)` at `main.cpp:139`. The `Renderer` lambda (`main.cpp:92`) reads `current_render` under `render_mtx` and returns it. The `CatchEvent` lambda handles `q` and `Escape` to set `ui_running = false` and call `screen.Exit()`.

### Synchronization Points

| Shared resource | Protector | Access pattern |
|---|---|---|
| `Stats` internal maps | `Stats::mtx` | Capture thread writes; UI thread reads via update_* methods |
| `StatsSnapshot` inside Stats | `Stats::mtx` | Both threads; snapshot is updated in place under lock |
| `current_render` | `render_mtx` | UI thread writes; FTXUI renderer reads |
| `capture_finished`, `ui_running` | `std::atomic<bool>` | Multiple threads read/write |
| `timer` | `std::atomic<std::chrono::seconds>` | UI thread writes; render lambda reads |

## Components

### PcapCapture (`include/capture/pcapCapture.hpp`, `src/capture/pcapCapture.cpp`)

Wraps the entire libpcap lifecycle. Owns the pcap handle as a `unique_ptr<pcap_t, decltype(&pcap_close)>` so it's released on destruction regardless of how the object exits.

Key responsibilities:
- `initialize()` — discover all network interfaces via `pcap_findalldevs()`
- `datalink_type()` — detect the link-layer header type and set the byte offset + EtherType extractor
- `start()` — open device in promiscuous mode, compile and install BPF filter, spawn capture thread
- `start_offline()` — open pcap file, process synchronously (no extra thread)
- `got_packet()` — parse each raw frame: extract EtherType, construct `IPv4` or `IPv6`, build `Packet`, forward to `Stats`
- `~PcapCapture()` — calls `stop()`: breaks pcap loop, joins thread, frees filter program and interface list

The C-style `pcap_loop` callback requires a static function. `callback()` (line 132) uses the `user` pointer (which holds `this` cast to `u_char*`) to forward to the instance method `got_packet()`.

### IP_class / IPv4 / IPv6 (`include/packet/IP.hpp`, `src/packet/IP.cpp`)

Polymorphic IP header parser. `IP_class` is an abstract base declaring pure virtual transport handlers (`handle_tcp()`, `handle_udp()`, etc.). Both `IPv4` and `IPv6` inherit from it.

Parsing is constructor-based: both `IPv4(const u_char *data)` and `IPv6(const u_char *data)` accept a pointer to the IP header (already offset past the link-layer header) and complete all parsing in the constructor. After construction, the object exposes only pure accessors: `get_source()`, `get_dest()`, `get_src_port()`, `get_dest_port()`, `get_protocol()`, `get_payload_len()`, `get_payload_ptr()`.

IPv4 transport dispatch: `switch(ip_hdr->ip_p)` at line 28, dispatching to `handle_tcp/udp/icmp/icmpv6/igmp`.

IPv6 transport dispatch: a `while(true)` loop at line 94 that either handles a transport protocol (and returns) or walks past a known extension header and continues.

### Packet (`include/packet/packet.hpp`, `src/packet/packet.cpp`)

A value type holding everything extracted from a single frame:
- `ip_version` — `v4` or `v6` (enum `IPVersion`)
- `transport_protocol` — TCP/UDP/ICMP/ICMP6/IGMP/UNKNOWN (enum class `TransportProtocol`)
- `application_protocol` — HTTP/HTTPS/DNS/SSH/etc (enum class `ApplicationProtocol`)
- `src`, `dst` — IP addresses as strings
- `src_port`, `dst_port` — port numbers
- `total_len` — full frame length from pcap header
- `payload_len` — transport payload length
- `payload_ptr` — pointer into pcap's buffer, nulled after `get_application_protocol()` runs

The constructor computes `application_protocol` via `get_application_protocol()` (packet.cpp:4) then immediately nulls `payload_ptr`. This prevents callers from dereferencing a pointer that's only valid during the callback.

`get_application_protocol()` uses payload inspection first (HTTP verbs, TLS record header bytes), then falls back to port-based identification.

### Stats (`include/stats/protocolStats.hpp`, `src/stats/protocolStats.cpp`)

Thread-safe statistics engine. Internal state:
- `transport_map` — `unordered_map<TransportProtocol, protocolStats>`
- `application_map` — `unordered_map<ApplicationProtocol, protocolStats>`
- `ip_map` — `unordered_map<string, IPStats>` (per-IP bidirectional counters)
- `pairs` — `map<pair<string,string>, protocolStats>` (per src→dst pair)
- `packets` — `deque<Packet>` (bounded ring of recent packets)
- `snapshot` — `StatsSnapshot` (pre-built display rows, updated by `update_*` methods)
- `bandwidth_history` — `vector<BandwidthPoint>` (time-series)

`add_packet()` (line 19) takes a lock and updates all raw maps in a single critical section. The `update_*()` methods take the lock, sort/format the data, and rebuild the corresponding `snapshot.*_rows` vectors. `get_snapshot()` returns a copy of the snapshot under the lock.

### View (`include/TUI/view.hpp`, `src/TUI/view.cpp`)

Stateless FTXUI layout composer. `render()` (view.cpp:5) builds the full terminal layout from a `StatsSnapshot`:

```
┌─────── header ──────────────────────────────────────┐
│ title | interface | filter  │  traffic summary       │
├─────────────────────────────────────────────────────┤
│ transport table │ app table │ pairs table            │  ← hbox, bordered
├──────────────────────────────────────────────────────┤
│ IP table (scrollable)  │  bandwidth graph            │  ← hbox
├─────────────────────────────────────────────────────┤
│ packets table (right panel, scrollable, width=100)   │
├─────────────────────────────────────────────────────┤
│ footer: timer + exit hint                            │
└─────────────────────────────────────────────────────┘
```

`render_bandwidth()` (line 138) defines a `GraphFunction` — a lambda that receives the graph widget's pixel dimensions and returns a `vector<int>` mapping each x-pixel to a y-height. It interpolates between the last 50 bandwidth samples and scales by `max_bandwidth`.

All table sections use `ftxui::Table` with header row styling (`DOUBLE` border on row 0, `LIGHT` on rest).

### Filter (`include/cli/filter.hpp`, `src/cli/filter.cpp`)

Two-function module:

`parse(str)` (filter.cpp:5) — splits a `key:value` string at the first `:`. Maps known key names (`protocol`, `port`, `src`, `dst`, `ip`) to the `filter_type` enum. Throws `std::invalid_argument` if no `:` is present.

`get_bpf_filter(filters)` (filter.cpp:27) — groups multiple filters by type into a `map<filter_type, vector<string>>`. Maps user-facing values to BPF syntax (e.g., `protocol:dns` → `port 53`, `ip:v4` → `ip`). Combines same-type filters with `or`, different types with `and`. Returns the resulting BPF expression string.

### argsParser (`include/cli/argsParse.hpp`, `src/cli/argsParse.cpp`)

Thin wrapper around `Boost.Program_options`. Defines all CLI options in the constructor and stores parsed results in a public `po::variables_map vm`. Options:

| Flag | Default | Description |
|------|---------|-------------|
| `-i`, `--interface` | `wlan0` | Network interface |
| `-c`, `--count` | `0` (unlimited) | Packet count limit |
| `--time`, `-t` | `INT_MAX` | Capture duration (seconds) |
| `-r`, `--offline` | — | Read from pcap file |
| `-f`, `--filter` | — | Filter expressions (composing, multiple) |
| `-n`, `--limit` | `43` | Max displayed entries |
| `--csv` / `--json` | — | Export paths |

## Data Flow

### Live Capture

```
User: just run -i eth0 -f protocol:tcp
  ↓
main.cpp:33-47   Parse args, build filter vector
main.cpp:49      get_bpf_filter() → "tcp" BPF string
main.cpp:54      capture.set_capabilities(interface, count, "tcp", limit, &stats)
main.cpp:73      capture.start()
  ↓
pcapCapture.cpp:52-64  pcap_lookupnet → pcap_open_live (promiscuous, SNAP_LEN=1518)
pcapCapture.cpp:64     datalink_type() → set offset + get_ether_type lambda
pcapCapture.cpp:68-75  pcap_compile + pcap_setfilter (BPF "tcp" installed in kernel)
pcapCapture.cpp:80-87  spawn thread → pcap_loop(callback)
  ↓
[Capture thread: per-packet]
pcapCapture.cpp:132-136  callback() → got_packet()
pcapCapture.cpp:158      get_ether_type(packet) → ETHERTYPE_IP or ETHERTYPE_IPV6
pcapCapture.cpp:162      IPv4 ip(packet + offset)  — constructor parses headers
  IP.cpp:18-50              extract src/dst, walk to TCP/UDP handler
  IP.cpp:52-61              handle_tcp: ports, payload_ptr, payload_len
pcapCapture.cpp:165-168  Packet packetView(...) — constructor runs get_application_protocol()
  packet.cpp:4-57            memcmp payload bytes, port-based fallback
                             payload_ptr = nullptr
pcapCapture.cpp:167      stats->add_packet(packetView) — lock, update all maps
pcapCapture.cpp:168      stats->push(packetView)       — lock, push to deque
  ↓
[UI update thread: every loop iteration]
main.cpp:117-121  update_transport_stats(), update_application_stats(),
                  update_ip_stats(10), update_pairs(), update_bandwidth()
main.cpp:124-126  view.render(stats.get_snapshot(), ...) → Element
main.cpp:127-130  store in current_render under render_mtx, PostEvent to FTXUI
  ↓
[FTXUI main thread: on Custom event]
main.cpp:92-95  Renderer lambda reads current_render under render_mtx → display
```

### Offline Analysis

```
main.cpp:61-70   capture.start_offline(pcap_file)   — runs synchronously
  pcapCapture.cpp:199-211  pcap_open_offline → pcap_loop (no thread)
  [same per-packet flow as above]
main.cpp:64-69   stats.update_packets() + update_application_stats() + ...
  ↓
main.cpp:86-88   view.render(stats.get_snapshot(), ...) → initial current_render
screen.Loop()    FTXUI displays static result (no UI update thread spawned)
```

## Design Decisions

### Decision: Constructor-Based Parsing vs Lazy Getters

The original `IP_class` design had `get_protocol()` as the entry point to all parsing — a getter with side effects. This creates hidden order dependencies: `get_src_port()` before `get_protocol()` returns 0 on IPv4 or garbage on IPv6.

The merged code (visible in the current `IPv4`/`IPv6` constructors) parses everything at construction time. Getters return already-computed values. No ordering requirements for callers.

### Decision: StatsSnapshot as Value Type

`StatsSnapshot` holds the pre-formatted display data as `vector<vector<string>>` rows. The UI thread calls `get_snapshot()` which copies this struct out under the mutex. The FTXUI renderer then works from its own copy with no need to hold any lock.

The alternative — having the renderer lock Stats directly — would mean the render mutex and the stats mutex interact, risking deadlock or blocking the capture thread on UI work.

### Decision: RAII Handle for pcap_t

`pcap_t*` is a C resource with `pcap_close()` as its destructor. Storing it as `unique_ptr<pcap_t, decltype(&pcap_close)>` means it's released automatically when `PcapCapture` is destroyed, even if exceptions fly. `handle.reset()` in `stop()` explicitly releases it early when the capture ends.

### Decision: Offset + Lambda for Link Types

Rather than if-chains scattered across `got_packet()`, the `datalink_type()` method sets both the `offset` integer and the `get_ether_type` function object once when the device opens. `got_packet()` stays clean: `uint16_t ether_type = get_ether_type(packet)`.

This makes adding a new link type a single `case` addition in `datalink_type()` rather than a change to the hot path.
