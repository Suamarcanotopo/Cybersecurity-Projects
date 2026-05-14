# Implementation Walkthrough

This document walks through every major component with exact file and line references. Read the source alongside this.

## Entry Point — `main.cpp`

### Initialization (lines 14–18)

```cpp
Stats stats;
PcapCapture capture;
capture.initialize();
argsParser parser(argc, argv);
```

`Stats` default-constructs with all maps empty and `last_tick` set to now. `PcapCapture` initializes its `handle` with `nullptr`. `initialize()` calls `pcap_findalldevs()` to populate the `interfaces` linked list so `--interfaces` can print them.

### Argument Handling (lines 24–47)

```cpp
if (parser.vm.contains("help")) { parser.print_help(); return 0; }
if (parser.vm.contains("interfaces")) { capture.print_interfaces(); return 0; }
```

Boost's `variables_map::contains()` checks if the flag was passed. Early-exit before any network setup.

```cpp
std::vector<filter> filters;
if (parser.vm.contains("filter")) {
    auto &f = parser.vm["filter"].as<std::vector<std::string>>();
    for (auto &x : f) { filters.push_back(parse(x)); filterString += x + " "; }
}
std::string expression = get_bpf_filter(filters);
```

`--filter` is a composing option — it can appear multiple times and Boost accumulates all values into a `vector<string>`. Each `key:value` string is parsed to a `filter` struct, then `get_bpf_filter()` combines them into a single BPF expression.

### Offline vs Live Path (lines 51–74)

```cpp
bool isOffline = parser.vm.contains("offline");
capture.set_capabilities(interface, count, expression, limit, &stats);

if (isOffline) {
    capture.start_offline(parser.vm["offline"].as<std::string>());
    stats.update_packets();
    stats.update_application_stats();
    // ...all update methods
}
else {
    capture.start();
}
```

`set_capabilities()` stores the config inside `PcapCapture` and calls `stats->set_packets_limit(packets_limit)`. For offline mode, `start_offline()` runs synchronously and blocks until the entire file is processed — no threading. All stats are then computed once before the TUI launches. For live mode, `start()` spawns the capture thread and returns immediately.

### FTXUI Setup (lines 78–104)

```cpp
auto screen = ftxui::ScreenInteractive::Fullscreen();
View view;
std::mutex render_mtx;
ftxui::Element current_render = isOffline
    ? view.render(stats.get_snapshot(), ...)
    : ftxui::text("Starting capture...");

auto component = ftxui::Renderer([&] {
    std::lock_guard<std::mutex> lock(render_mtx);
    return current_render;
});

component |= ftxui::CatchEvent([&](ftxui::Event e) {
    if (e == ftxui::Event::Character('q') || e == ftxui::Event::Escape) {
        ui_running = false;
        screen.Exit();
        return true;
    }
    return true;
});
```

`current_render` holds the last-built element. The `Renderer` lambda is called by FTXUI's event loop on every repaint — it just returns whatever's in `current_render`, protected by `render_mtx`. The `CatchEvent` lambda intercepts keyboard events. Returning `true` means "event consumed, don't propagate".

Note: `return true` for all events (not just q/Esc) is intentional — it prevents FTXUI's default behavior from processing other keys.

### UI Update Thread (lines 106–137)

```cpp
application_thread = std::thread([&] {
    while (!capture_finished && ui_running) {
        auto now = std::chrono::steady_clock::now();
        timer.store(std::chrono::duration_cast<std::chrono::seconds>(now - begin));

        if (timer.load() >= std::chrono::seconds(time) || !capture.isRunning())
            capture_finished = true;

        stats.update_packets();
        stats.update_application_stats();
        stats.update_transport_stats();
        stats.update_ip_stats(10);
        stats.update_pairs();
        stats.update_bandwidth();

        ftxui::Element new_frame = view.render(stats.get_snapshot(), ...);
        { std::lock_guard<std::mutex> lock(render_mtx); current_render = new_frame; }
        if (ui_running) screen.PostEvent(ftxui::Event::Custom);
    }
});
```

The loop updates stats, builds a new FTXUI element tree from the snapshot, swaps it into `current_render` (under lock), and tells the FTXUI event loop to repaint. `PostEvent(Custom)` is non-blocking — it enqueues the event and returns.

No explicit `sleep_for` in the loop (it's commented out at line 134). The loop runs as fast as the update methods complete, which is bounded by the stats mutex contention.

---

## PcapCapture — `src/capture/pcapCapture.cpp`

### `start()` (lines 50–88)

```cpp
handle.reset(pcap_open_live(interface.c_str(), SNAP_LEN, 1, 1000, errbuf));
```

- `SNAP_LEN = 1518` — maximum bytes to capture per packet (standard Ethernet MTU + headers)
- `1` — promiscuous mode on
- `1000` — read timeout in milliseconds (how long pcap_loop blocks waiting for packets)

```cpp
datalink_type(pcap_datalink(handle.get()));
```

Detects the link type and sets `offset` + `get_ether_type` before any packets arrive.

```cpp
if (pcap_compile(handle.get(), &fp, filter_exp.c_str(), 0, net) == -1)
    throw std::runtime_error(...);
if (pcap_setfilter(handle.get(), &fp) == -1)
    throw std::runtime_error(...);
```

BPF compilation is into `struct bpf_program fp` (stack-allocated). After installation, the kernel runs this BPF program on every incoming frame.

```cpp
thread = std::thread([this]() {
    if (pcap_loop(handle.get(), num_packets, &PcapCapture::callback, reinterpret_cast<u_char *>(this)) < 0) {}
    running = false;
});
```

`pcap_loop` blocks the thread until `num_packets` are captured (0 = unlimited) or `pcap_breakloop()` is called. `this` is passed as the `user` pointer — the static `callback` function casts it back to `PcapCapture*` to call `got_packet()`.

### `stop()` (lines 90–108)

```cpp
pcap_freecode(&fp);          // release BPF program memory
if (!handle) return;
running = false;
pcap_breakloop(handle.get()); // signal pcap_loop to exit on next packet
if (thread.joinable()) thread.join(); // wait for capture thread to finish
handle.reset();               // calls pcap_close via unique_ptr deleter
if (interfaces) { pcap_freealldevs(interfaces); interfaces = nullptr; }
```

Called from the destructor. Order matters: break the loop first, then join, then close the handle.

### `got_packet()` (lines 152–179)

```cpp
uint16_t ether_type = get_ether_type(packet);

if (ether_type == ETHERTYPE_IP) {
    IPv4 ip(packet + offset);
    TransportProtocol prot = ip.get_protocol();
    Packet packetView(v4, prot, ip.get_source(), ip.get_dest(),
                      ip.get_src_port(), ip.get_dest_port(),
                      header->len, ip.get_payload_len(), ip.get_payload_ptr());
    stats->add_packet(packetView);
    stats->push(packetView);
}
```

`packet + offset` skips past the link-layer header (14, 16, or 20 bytes depending on DLT type). `IPv4 ip(packet + offset)` parses all headers in the constructor. `Packet` construction calls `get_application_protocol()` and nulls `payload_ptr`. Then both `add_packet()` (updates all maps) and `push()` (pushes to the recent-packets deque) are called — both take the stats mutex internally.

---

## IP Parsing — `src/packet/IP.cpp`

### IPv4 Constructor (lines 18–50)

```cpp
ip_hdr = reinterpret_cast<const ip *>(data);
src = inet_ntoa(ip_hdr->ip_src);    // converts in_addr to "a.b.c.d" string
dst = inet_ntoa(ip_hdr->ip_dst);
ip_hdr_len = ip_hdr->ip_hl * 4;    // ip_hl is 4-bit field: header length in 32-bit words
if (ip_hdr_len < 20) throw std::runtime_error("Failed to initial IPv4 ");
```

`ip_hl * 4`: the Internet Header Length field is 4 bits, measured in 32-bit words. Minimum value is 5 (= 20 bytes, no options). Cast to bytes by multiplying by 4.

```cpp
switch (ip_hdr->ip_p) {
case IPPROTO_TCP:  IPv4::handle_tcp();  break;
case IPPROTO_UDP:  IPv4::handle_udp();  break;
case IPPROTO_ICMP: IPv4::handle_icmp(); break;
// ...
}
```

`ip_p` is the Protocol field (byte 9 of the IP header). IANA assigns these: 6 = TCP, 17 = UDP, 1 = ICMP.

### IPv4 TCP Handler (lines 52–62)

```cpp
const auto *tcp = reinterpret_cast<const tcphdr *>(
    reinterpret_cast<const u_char *>(ip_hdr) + ip_hdr_len
);
src_port = ntohs(tcp->source);
dest_port = ntohs(tcp->dest);
payload_ptr = reinterpret_cast<const u_char *>(tcp) + tcp->doff * 4;
payload_len = ntohs(ip_hdr->ip_len) - (ip_hdr_len + tcp->doff * 4);
```

`ip_hdr` points to the IP header. Adding `ip_hdr_len` bytes (cast to `u_char*` first for byte arithmetic) lands on the TCP header. `tcp->doff` is the TCP Data Offset: number of 32-bit words in the TCP header. `tcp->doff * 4` gives bytes. Payload starts after the TCP header.

`ntohs()` converts from network byte order (big-endian) to host byte order. All multi-byte fields in network protocols are big-endian.

### IPv6 Extension Header Walking (lines 82–136)

```cpp
ptr = reinterpret_cast<const uint8_t *>(ip_hdr + 1); // past the 40-byte fixed header
while (true) {
    switch (hdr) {
    case IPPROTO_TCP: IPv6::handle_tcp(); return;
    // ...
    case IPPROTO_HOPOPTS:
    case IPPROTO_ROUTING:
    case IPPROTO_DSTOPTS: {
        const auto *ext = reinterpret_cast<const ip6_ext *>(ptr);
        hdr = ext->ip6e_nxt;
        ptr += (ext->ip6e_len + 1) * 8;
        break;
    }
    case IPPROTO_FRAGMENT: {
        const auto *frag = reinterpret_cast<const ip6_frag *>(ptr);
        hdr = frag->ip6f_nxt;
        ptr += sizeof(ip6_frag);
        break;
    }
    default: protocol = TransportProtocol::UNKNOWN; return;
    }
}
```

`ip_hdr + 1` — pointer arithmetic on `ip6_hdr*` advances by `sizeof(ip6_hdr) = 40` bytes, landing exactly at the first extension header or transport header.

`(ext->ip6e_len + 1) * 8` — RFC 2460 formula. `ip6e_len` is the length in 8-byte units not counting the first 8 bytes. So total bytes = `(len + 1) * 8`.

---

## Application Protocol Detection — `src/packet/packet.cpp`

### Two-Phase Identification (lines 4–57)

```cpp
ApplicationProtocol Packet::get_application_protocol() {
    if (!payload_ptr || payload_len < 4) goto check_port;

    if (transport_protocol == TransportProtocol::TCP) {
        if (!memcmp(payload_ptr, "GET ", 4) || !memcmp(payload_ptr, "POST", 4) || ...)
            return ApplicationProtocol::HTTP;
    }
    if ((src_port == 53 || dst_port == 53) && payload_len >= 12)
        return ApplicationProtocol::DNS;
    if (transport_protocol == TransportProtocol::TCP && payload_len >= 3) {
        if (payload_ptr[0] == 0x16 && payload_ptr[1] == 0x03)
            return ApplicationProtocol::HTTPS;
    }

check_port:
    uint16_t port = (src_port < dst_port) ? src_port : dst_port;
    // switch on port ...
}
```

Phase 1 — payload inspection. `memcmp(payload_ptr, "GET ", 4)` compares the first 4 payload bytes against the literal string. HTTP/1.x requests always start with a verb. TLS records start with `0x16 0x03` (Content-Type=Handshake, Version=3.x).

Phase 2 — port fallback via `goto check_port`. Using `goto` to jump past Phase 1 when payload is null or too short. `port = min(src_port, dst_port)` — for client→server connections, the server port is typically the well-known one and will be numerically smaller.

---

## Statistics Engine — `src/stats/protocolStats.cpp`

### `add_packet()` (lines 19–42)

```cpp
void Stats::add_packet(const Packet &packet) {
    std::lock_guard<std::mutex> lock(mtx);

    ++snapshot.total_p;
    snapshot.total_b += packet.total_len;

    auto &t = transport_map[packet.transport_protocol];
    t.packets++;
    t.bytes += packet.total_len;

    auto &a = application_map[packet.application_protocol];
    a.packets++;
    a.bytes += packet.payload_len;

    ip_map[packet.src].packets_sent++;
    ip_map[packet.src].bytes_sent += packet.total_len;
    ip_map[packet.dst].packets_received++;
    ip_map[packet.dst].bytes_received += packet.total_len;

    auto key = std::make_pair(packet.src, packet.dst);
    pairs[key].packets++;
    pairs[key].bytes += packet.total_len;
}
```

`unordered_map::operator[]` default-constructs the value if the key doesn't exist. `protocolStats` has all members zero-initialized by default, so the first packet for any protocol inserts a zero-struct and then increments. Same pattern for `IPStats` and the `pairs` map.

Note: `total_p` and `total_b` are updated directly in `snapshot` (not in a separate struct) so they're immediately visible in `get_snapshot()` without an extra `update_*` call.

### `update_transport_stats()` (lines 93–107)

```cpp
std::vector<std::pair<TransportProtocol, protocolStats>> tps(transport_map.begin(), transport_map.end());
std::sort(tps.begin(), tps.end(), [](auto &a, auto &b) { return a.second.packets > b.second.packets; });
```

Can't sort `unordered_map` in place — copy to a vector first, then sort. The lambda compares by packet count descending. Each row is then formatted with `std::format("{:.2f}", ...)` for MB and percentage values.

### `update_bandwidth()` (lines 230–252)

```cpp
auto now = steady_clock::now();
double elapsed = duration_cast<duration<double>>(now - last_tick).count();

if (elapsed >= 1.0) {
    uint32_t delta_bytes = snapshot.total_b - last_b;
    snapshot.bandwidth = delta_bytes / elapsed;
    last_b = snapshot.total_b;
    last_tick = now;

    const double alpha = 0.2;
    smooth_bandwidth = alpha * snapshot.bandwidth + (1.0 - alpha) * smooth_bandwidth;
    snapshot.bandwidth_history.push_back({ts, smooth_bandwidth});
}
snapshot.max_bandwidth = std::max(snapshot.max_bandwidth, snapshot.bandwidth);
```

Only samples once per second (when `elapsed >= 1.0`). `delta_bytes = current_total - last_snapshot_total`. Divided by elapsed seconds = bytes/sec. The EMA with alpha=0.2 smooths out spikes. `max_bandwidth` is updated every call (not just when a second has elapsed) so it tracks the actual peak.

---

## Filter Builder — `src/cli/filter.cpp`

### `parse()` (lines 5–25)

```cpp
filter parse(const std::string &str) {
    auto pos = str.find(':');
    if (pos == std::string::npos)
        throw std::invalid_argument("Invalid filter format: '" + str + "' (expected key:value)");
    std::string type = str.substr(0, pos);
    std::string value = str.substr(pos + 1);
    if (type == "protocol") return {PROTOCOL, value};
    if (type == "port")     return {PORT, value};
    if (type == "dest")     return {IP_DEST, value};
    if (type == "src")      return {IP_SRC, value};
    if (type == "ip")       return {IP_TYPE, value};
    return {NONE, value};
}
```

`find(':')` returns `string::npos` (max value of `size_t`) if not found. The throw prevents the `npos + 1` unsigned overflow bug that would otherwise make `substr(npos + 1)` return the whole string as the value.

### `get_bpf_filter()` (lines 27–97)

```cpp
std::map<filter_type, std::vector<std::string>> groups;
for (const auto &x : f) {
    switch (x.type) {
    case PROTOCOL:
        if (x.val == "dns") groups[PROTOCOL].emplace_back("port 53");
        else if (x.val == "http") groups[PROTOCOL].emplace_back("port 80");
        // ...
        break;
    case IP_TYPE:
        if (x.val == "v4" || x.val == "4" || x.val == "ipv4") groups[IP_TYPE].emplace_back("ip");
        else if (x.val == "v6" || ...) groups[IP_TYPE].emplace_back("ip6");
        else throw std::invalid_argument("Unknown IP type: '" + x.val + "'");
        break;
    }
}
// combine: same-type = OR, different types = AND
for (auto &[type, parts] : groups) {
    if (!first_group) result += " and ";
    if (parts.size() > 1) result += "(";
    for (size_t i = 0; i < parts.size(); ++i) {
        result += parts[i];
        if (i + 1 < parts.size()) result += " or ";
    }
    if (parts.size() > 1) result += ")";
}
```

`std::map` (ordered) ensures deterministic output order regardless of insertion order. The BPF AND/OR combination follows standard network filter semantics: same filter type with multiple values means "match any of these" (OR), while different filter types must all match (AND).

Example: `-f protocol:http -f protocol:https -f port:8080` → `(port 80 or port 443 or port 8080)`

---

## TUI Rendering — `src/TUI/view.cpp`

### Layout Composition (lines 5–47)

```cpp
auto transport_section = hbox({
    render_transport(data) | flex,
    separator(),
    render_application(data) | flex,
    separator(),
    render_pairs(data) | flex,
}) | border;

auto ip_section = hbox({
    render_ip(data) | border | size(HEIGHT, LESS_THAN, 10) | frame | vscroll_indicator,
    render_bandwidth(data) | border | flex
});

auto right_panel = render_packets(data) | border | size(WIDTH, EQUAL, 100) | frame | vscroll_indicator;
```

FTXUI uses a declarative layout model. `hbox` places elements side by side. `| flex` makes an element expand to fill available space. `| size(HEIGHT, LESS_THAN, 10)` caps height. `| frame | vscroll_indicator` adds scroll support.

`separator()` draws a vertical line between elements.

### Bandwidth Graph (lines 138–175)

```cpp
GraphFunction fn = [this, data](int width, int height) {
    std::vector<int> output(width, 0);
    size_t n = data.bandwidth_history.size();
    size_t start = n > 50 ? n - 50 : 0;  // last 50 samples

    double max_bw = 1.0;
    for (size_t i = start; i < n; ++i)
        max_bw = std::max(max_bw, data.bandwidth_history[i].bytes_per_sec);

    for (int x = 0; x < width; ++x) {
        double t = (double)x / (width - 1);
        double idx_f = start + t * (n - start - 1);
        size_t i0 = (size_t)idx_f;
        size_t i1 = std::min(i0 + 1, n - 1);
        double frac = idx_f - i0;
        double bw = data.bandwidth_history[i0].bytes_per_sec * (1.0 - frac)
                  + data.bandwidth_history[i1].bytes_per_sec * frac;
        output[x] = static_cast<int>(bw / max_bw * (height - 1));
    }
    return output;
};
```

The `GraphFunction` maps `width` screen columns to `height`-bounded integer heights. For each pixel column `x`, it computes a fractional index into the sample array (mapping the screen width to the sample range), interpolates linearly between adjacent samples, then normalizes to the graph height. `max_bw = 1.0` as the floor prevents division by zero when no traffic has been seen yet.

### Table Rendering (lines 83–93, pattern repeated for all tables)

```cpp
Table table(data.transport_rows);
table.SelectAll().Border(LIGHT);
table.SelectRow(0).Decorate(bold);
table.SelectRow(0).SeparatorVertical(LIGHT);
table.SelectRow(0).Border(DOUBLE);
return vbox({text("=== Transport protocols === ") | bold, table.Render()}) | flex;
```

`data.transport_rows` is a `vector<vector<string>>` where row 0 is the header. `SelectAll().Border(LIGHT)` draws light borders around all cells. `SelectRow(0).Border(DOUBLE)` overrides the header row with a double border to visually distinguish it. `SelectRow(0).Decorate(bold)` makes header text bold.
