# Challenges and Extensions

These are concrete things you can build on top of the existing codebase. Each one has a clear starting point in the code and a reason why it's worth doing.

## Beginner

### 1. Add ICMP Type Breakdown

Right now ICMP packets count as a single protocol entry. ICMP carries many message types: echo request/reply (ping), port unreachable, time exceeded (traceroute hops), etc.

**What to do:** In `IPv4::handle_icmp()` (`src/packet/IP.cpp:73`), cast the payload to `icmphdr` and read `type` and `code`. Extend `ApplicationProtocol` in `packet.hpp` to include `ICMP_ECHO`, `ICMP_UNREACHABLE`, etc., or add a separate `icmp_type` field to `Packet`.

**Why it matters:** ICMP is frequently used for recon (ping sweeps) and for covert channels (ICMP tunneling tools like `icmptunnel` encode data in the payload). Being able to distinguish echo requests from unreachable messages tells you whether you're being scanned or whether routes are broken.

### 2. Color-Code Protocols in the TUI

Add color to the transport and application protocol tables — TCP in blue, UDP in green, ICMP in yellow, unknown in red.

**What to do:** In `view.cpp:render_transport()`, access individual cells with `table.SelectCell(row, col).Decorate(color(Color::Blue))`. FTXUI's `Table::SelectCell()` takes row and column indices.

**Why it matters:** Security operators scan dashboards under time pressure. Color coding lets the eye jump to anomalies (unexpected UDP traffic, unknown protocols) without reading every row.

### 3. Add a Packet Rate Counter

Display packets/sec alongside the bandwidth graph. The bandwidth graph shows bytes/sec, but packet rate is separately useful — a flood of tiny packets at low bandwidth is a different pattern than a few large transfers.

**What to do:** Add `uint32_t last_p = 0` to `Stats` (alongside `last_b`). In `update_bandwidth()` (`protocolStats.cpp:230`), compute `delta_packets / elapsed` alongside the existing byte calculation. Add it to `StatsSnapshot` and display it in `render_header()` or `render_stats()`.

---

## Intermediate

### 4. TCP Stream Reassembly

Right now each TCP packet is analyzed independently. Application-level protocols that span multiple packets (HTTP responses, FTP transfers) aren't reconstructed. Reassembly combines TCP segments in sequence number order into a stream.

**What to do:** Add a `StreamTable` class that maps `(src_ip, dst_ip, src_port, dst_port)` to an ordered buffer of segments (keyed by sequence number). In `got_packet()` (`pcapCapture.cpp:152`), after constructing a TCP `Packet`, insert it into the stream table. When segments arrive in order, append to the stream buffer. When a gap fills, run application-layer identification on the complete buffer.

**Why it matters:** HTTP detection by verb matching (`memcmp(payload_ptr, "GET ", 4)` in `packet.cpp:9`) only works if the HTTP request fits in the first packet. For large PUT/POST bodies or slow connections, the verb might be in an earlier segment that's already been processed. Reassembly is how Snort, Suricata, and commercial DPI engines handle this.

### 5. DNS Query Logging

Extract DNS query names from UDP packets on port 53 and log them with timestamps.

**What to do:** In `Packet::get_application_protocol()` (`packet.cpp:14`), when DNS is identified, parse the DNS question section from `payload_ptr`. DNS is binary: bytes 0–11 are the header (ID, flags, counts), bytes 12+ are the question section as a length-prefixed label sequence (e.g., `\x03www\x07example\x03com\x00`). Walk the labels to extract the FQDN. Add a `dns_query` string field to `Packet` and display it in the packets table.

**Why it matters:** DNS is the phone book attackers always use. C2 beacons check in via DNS. Data exfiltration encodes data in DNS queries (DNS tunneling). A simple query log catches malware like `dnscat2` which uses DNS TXT records for a command shell — the queries show absurdly long subdomain names.

### 6. Alert Rules Engine

Add a rule evaluation engine that fires alerts when traffic matches configurable conditions: "alert if any single IP sends > 1000 packets in 10 seconds" (port scan), "alert if DNS queries/sec > 100" (tunneling), "alert if a new IP appears that wasn't in baseline" (lateral movement).

**What to do:** Create an `AlertRule` struct with a condition function and threshold. Create an `AlertEngine` that the UI update thread calls after `update_ip_stats()`. Rules inspect the `Stats` snapshot for threshold violations. Store triggered alerts in a `deque<Alert>` and add a panel to `view.cpp` to display them.

**Why it matters:** This is the core of what a SIEM does. SIEMs (Splunk, Elastic SIEM, IBM QRadar) correlate events from multiple sources, but the underlying idea — evaluate rule conditions against observed metrics, fire alert when exceeded — is what you're building here.

---

## Advanced

### 7. Packet Payload Hex Dump

Add a detail view that shows the raw hex bytes and ASCII representation of a selected packet's payload — like Wireshark's bottom pane.

**What to do:** The `payload_ptr` is currently nulled after `get_application_protocol()` runs (`packet.hpp:53`). To support hex dump, copy the payload bytes into a `vector<uint8_t>` before nulling. Add a selected-packet index to `View` state, a way to navigate it (arrow keys via `CatchEvent`), and a `render_hex_dump()` method that formats bytes as `XX XX XX ... | .text..` rows.

FTXUI doesn't have a built-in hex dump widget. You'd build it with a series of `hbox({text(hex_col) | fixed(50), text(ascii_col)})` elements.

**Why it matters:** Payload inspection is how you verify that an alert is real. "DNS traffic" is easy to detect. Knowing whether that DNS traffic contains normal queries or base64-encoded exfiltration requires looking at the bytes.

### 8. Anomaly Baseline and Deviation Detection

Record a traffic baseline over a configurable window (e.g., first 60 seconds), then flag deviations. A new protocol appearing, a normally-quiet IP becoming a top talker, or TCP traffic on a UDP-only port all warrant investigation.

**What to do:** Add a `Baseline` class that snapshots `transport_map` and `ip_map` after the baseline window. Add a `compare(current_snapshot, baseline)` function that computes Z-scores or percentage deltas for each metric. Store deviations in a `vector<Deviation>` and render them in a new TUI panel.

**Why it matters:** The 2020 SolarWinds attack persisted undetected for 9 months partly because the malicious traffic mimicked normal Orion product telemetry — it looked like expected traffic to anyone checking manually. Automated baseline comparison would have flagged the new beacon pattern against the pre-compromise baseline.

### 9. PCAP Export During Live Capture

Let the user write a `.pcap` file of captured traffic in real time, not just export stats at the end. This enables offline analysis in Wireshark after the fact.

**What to do:** Use `pcap_dump_open()` to create a dump file handle, and `pcap_dump()` inside `got_packet()` (`pcapCapture.cpp:152`) to write each raw packet with its `pcap_pkthdr`. Add a `--write` flag to `argsParser` (`argsParse.cpp`). The dump handle is another C resource that benefits from RAII wrapping.

**Why it matters:** Live capture tools in incident response always write pcap files. You want to capture first, analyze later — especially if the attack is still in progress. Tools like `tcpdump -w` and `dumpcap` do exactly this.

### 10. Protocol-Aware Port Scanning Detection

Detect SYN-only streams (where TCP connections are initiated but never completed) and flag them as potential port scans.

**What to do:** In the TCP stream table (from challenge 4), track TCP flags on each packet. A SYN with no SYN-ACK reply within a timeout is a half-open scan. Count the number of distinct destination ports from a single source IP within a time window — more than N unique ports in M seconds = probable scan. This is the algorithm `portsentry`, `snort`, and modern firewalls use.

The 2016 Mirai botnet scanned the entire IPv4 internet for open Telnet/SSH ports in under an hour by running SYN scans from 100,000+ infected devices simultaneously. Detecting scan patterns at the packet level — not just counting connection attempts — is how network IDS systems catch this.
