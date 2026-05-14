# Concepts

## Packet Capture at the Kernel Level

When you open Wireshark and see packets, a lot has happened before the first byte reaches the screen. The OS kernel receives each frame off the network card, and normally only delivers frames addressed to your machine (or your subnet's broadcast address) to user processes. A packet sniffer needs everything — including frames addressed to other hosts.

This is promiscuous mode. When libpcap opens a device with `pcap_open_live(..., 1, ...)` (the `1` is the promiscuous flag, `pcapCapture.cpp:59`), it asks the kernel to pass all frames regardless of destination MAC address. The kernel network stack sees frames before the routing layer discards irrelevant ones.

The kernel copies matching frames from kernel space to a user-space ring buffer. Your program reads from that buffer via `pcap_loop()`. The copy is the bottleneck — that's why high-performance capture tools (like those used in data centers) use kernel bypass mechanisms like DPDK or XDP to skip the copy entirely.

## BPF — Berkeley Packet Filter

BPF is a small virtual machine that runs inside the kernel. When you pass a filter expression like `tcp and port 443`, libpcap compiles it to BPF bytecode and installs that program in the kernel. The kernel runs the BPF program on each frame before deciding whether to copy it to userspace.

The payoff: on a busy network, 99% of frames get dropped in the kernel without ever touching userspace. Moving filtering from user space to BPF reduced CPU usage from ~80% to ~5% in production network monitoring scenarios with port-specific filters.

In this project, `filter.cpp` builds BPF expression strings (`get_bpf_filter()`, line 27), and `pcapCapture.cpp` compiles and installs them via `pcap_compile()` + `pcap_setfilter()` (lines 68–75).

### Writing BPF Expressions

BPF syntax that pcap accepts:
```
tcp                        — only TCP traffic
port 443                   — source or destination port 443
host 192.168.1.1           — to or from specific IP
src host 10.0.0.1          — from specific source
dst host 10.0.0.1 and port 80  — combined with AND
tcp or udp                 — combined with OR
```

The project's filter builder maps its own key:value syntax to BPF:
- `protocol:https` → `port 443`
- `ip:v4` → `ip`
- `src:192.168.1.1` → `src host 192.168.1.1`
- Multiple filters of the same type are ORed, different types are ANDed

## Ethernet Frames and Link Layer Types

Every packet on a physical network starts with a link-layer header. On Ethernet (the common case), that's a 14-byte Ethernet header: 6 bytes destination MAC, 6 bytes source MAC, 2 bytes EtherType.

But not every interface uses Ethernet headers. The Linux `any` pseudo-interface uses `DLT_LINUX_SLL` (a synthetic 16-byte header). Some environments use `DLT_LINUX_SLL2` (20-byte header). The offset before the IP layer differs by link type.

`pcapCapture.cpp:datalink_type()` (lines 13–39) handles this with a switch on the link type returned by `pcap_datalink()`. It sets both the `offset` (how many bytes to skip before the IP layer) and a `get_ether_type` lambda that extracts the EtherType field from the correct position.

```
DLT_EN10MB  → offset = 14, EtherType at bytes 12-13
DLT_LINUX_SLL  → offset = 16, protocol at bytes 14-15
DLT_LINUX_SLL2 → offset = 20, protocol at bytes 18-19
```

EtherType `0x0800` = IPv4, `0x86DD` = IPv6. The `got_packet()` function (line 152) reads the EtherType from the packet using `get_ether_type(packet)` and dispatches to `IPv4` or `IPv6` accordingly.

## Protocol Header Parsing

After skipping the link-layer header, the IP header starts at `packet + offset`. The parsing is raw pointer casting:

```cpp
// IP.cpp:19 — cast raw bytes to ip header struct
ip_hdr = reinterpret_cast<const ip *>(data);
```

The `ip` struct from `<netinet/ip.h>` maps the fields at known byte offsets — `ip_hl` at bits 0–3 of byte 0 (the IP header length in 4-byte words), `ip_src` and `ip_dst` at bytes 12–15 and 16–19.

IP header length is `ip_hl * 4`. The minimum is 20 bytes (no options). IPv4.cpp validates this at line 25:
```cpp
if (ip_hdr_len < 20) throw std::runtime_error("Failed to initial IPv4 ");
```

The transport header immediately follows the IP header:
```cpp
// IP.cpp:53 — walk past the IP header to reach TCP
const auto *tcp = reinterpret_cast<const tcphdr *>(
    reinterpret_cast<const u_char *>(ip_hdr) + ip_hdr_len
);
```

The TCP header has its own variable length: `tcp->doff * 4` bytes (Data Offset field, minimum 20 bytes). The payload starts immediately after:
```cpp
// IP.cpp:58 — TCP payload pointer
payload_ptr = reinterpret_cast<const u_char *>(tcp) + tcp->doff * 4;
payload_len = ntohs(ip_hdr->ip_len) - (ip_hdr_len + tcp->doff * 4);
```

Note the `reinterpret_cast<const u_char *>(tcp)` before the addition. Pointer arithmetic on a typed pointer advances by multiples of `sizeof(T)` — without the cast to byte pointer, `tcp + doff * 4` would advance by `doff * 4 * sizeof(tcphdr)` bytes, which is 20x too far.

## Application Protocol Identification

Application protocol detection uses two strategies, tried in order (`packet.cpp:4–57`):

**Payload inspection (deep packet inspection):** Check the first bytes of the payload against known magic values:
- HTTP: first 4 bytes are `GET `, `POST`, `HEAD`, `PUT `, or `HTTP` (line 9)
- TLS/HTTPS: first byte is `0x16` (TLS record type = handshake), second is `0x03` (version major) (line 18)

**Port-based fallback:** When payload is absent or unrecognized, check well-known ports:
- TCP 22 → SSH, 25 → SMTP, 80 → HTTP, 443 → HTTPS
- UDP 53 → DNS, 443 → QUIC, 123 → NTP

The protocol identification happens in the `Packet` constructor (packet.hpp:52):
```cpp
application_protocol = get_application_protocol();
this->payload_ptr = nullptr;  // null after identification — payload no longer needed
```

Setting `payload_ptr = nullptr` after use is intentional. The pointer points into libpcap's internal ring buffer, which is only valid during the `pcap_loop` callback. Once the `Packet` is stored in `Stats.packets` deque, the pointer would be dangling. Nulling it makes this explicit.

## Thread Safety and the Snapshot Pattern

Two threads access the `Stats` object concurrently: the capture thread (calls `add_packet()`, `push()`) and the UI update thread (calls all the `update_*()` methods and `get_snapshot()`).

All `Stats` methods lock `mtx` at entry (`protocolStats.cpp:20`, `94`, `116`, `141`, etc.). Write operations complete under the lock. Reads via `get_snapshot()` (protocolStats.hpp:89) return a copy of the snapshot struct under the same lock:

```cpp
StatsSnapshot get_snapshot() {
    std::lock_guard<std::mutex> lock(mtx);
    return snapshot;  // copy-on-exit
}
```

The FTXUI render lambda in `main.cpp` (line 92) reads from `current_render` under `render_mtx`, not from `Stats` directly. The UI update thread in `application_thread` (line 107) calls `get_snapshot()`, builds a new FTXUI element tree, stores it in `current_render` under `render_mtx`, then posts a custom event to trigger a repaint:

```cpp
ftxui::Element new_frame = view.render(stats.get_snapshot(), ...);
{
    std::lock_guard<std::mutex> lock(render_mtx);
    current_render = new_frame;
}
screen.PostEvent(ftxui::Event::Custom);
```

This design means the FTXUI event loop thread never touches `Stats` directly — it only reads the pre-built `current_render` element.

## IPv6 Extension Headers

IPv6 dropped the options field from the fixed header and replaced it with extension headers — a chain of optional headers between the 40-byte base header and the transport layer. Each extension header has a `Next Header` field pointing to the next one in the chain.

The `IPv6` constructor (`IP.cpp:82–136`) walks this chain in a `while(true)` loop. At each iteration it reads the current header type and either dispatches to the transport handler (TCP/UDP/ICMP/ICMPV6/IGMP) and returns, or advances past a known extension header (Hop-by-Hop Options, Routing, Destination Options, Fragment) and continues:

```cpp
case IPPROTO_HOPOPTS:
case IPPROTO_ROUTING:
case IPPROTO_DSTOPTS: {
    const auto *ext = reinterpret_cast<const ip6_ext *>(ptr);
    hdr = ext->ip6e_nxt;
    ptr += (ext->ip6e_len + 1) * 8;  // len in 8-byte units, not counting first 8
    break;
}
```

The `(ext->ip6e_len + 1) * 8` arithmetic is the standard RFC 2460 formula: the length field counts 8-byte units excluding the first 8 bytes.

## Bandwidth Calculation

Bandwidth is computed once per second in `update_bandwidth()` (`protocolStats.cpp:230–252`):

```
delta_bytes = total_bytes_now - total_bytes_last_tick
bandwidth   = delta_bytes / elapsed_seconds  (bytes/sec)
```

Raw bandwidth is noisy (bursty traffic, variable tick timing), so an exponential moving average smooths it:
```cpp
const double alpha = 0.2;
smooth_bandwidth = alpha * snapshot.bandwidth + (1.0 - alpha) * smooth_bandwidth;
```

An alpha of 0.2 gives recent samples 20% weight and the historical average 80% weight. Lower alpha = smoother but more lag. The smoothed value is stored in `bandwidth_history` for the TUI graph.

The TUI graph in `view.cpp:138–174` maps the last 50 bandwidth samples onto the graph widget's width using linear interpolation between samples — scaling each sample to a height value based on the current maximum bandwidth.
