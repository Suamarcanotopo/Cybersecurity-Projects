# C++ Network Traffic Analyzer

## What This Is

A C++20 CLI tool that captures live network traffic or reads offline pcap files, parses raw Ethernet/IP/TCP/UDP frames manually, and renders real-time statistics in a fully interactive terminal UI. Built with libpcap for kernel-level packet capture, Boost for CLI parsing, and FTXUI for the TUI.

## Why This Matters

Network visibility is how defenders catch attackers. If you can't see what's crossing your network, you can't detect intrusions, data exfiltration, or lateral movement. Tools like Wireshark, Zeek, and Suricata all sit on the same foundation: libpcap.

**Real-world scenarios where this applies:**

- **Incident response:** During the 2013 Target breach, 40 million card numbers were exfiltrated through POS systems over BlackPOS malware that used standard TCP connections to external IPs. Packet-level visibility would have flagged the unexpected outbound traffic from in-store register machines.

- **APT detection:** The 2020 SolarWinds attack (CVE-2020-10148) used HTTP beaconing — periodic check-ins from compromised hosts to attacker-controlled servers. Anomaly detection at the packet layer catches this: hosts that never talked to external IPs suddenly start.

- **Protocol baseline:** You cannot detect what's abnormal without first knowing what's normal. Packet analyzers establish baseline distributions — how much is DNS versus HTTPS versus SMTP — so unexpected shifts register as alerts.

## What You'll Learn

**Security concepts:**

- **Raw socket access and capabilities** — Why packet capture requires root or `CAP_NET_RAW`, what Linux capabilities are, and how BPF (Berkeley Packet Filter) lets the kernel drop packets before they ever reach userspace.

- **Protocol header parsing** — How to walk the Ethernet frame → IP header → TCP/UDP header chain manually, using byte offsets and `reinterpret_cast`. This is what every IDS, DPI engine, and firewall does internally.

- **BPF filter expressions** — How to write and compile filters that run in the kernel (e.g., `tcp and port 443 and host 192.168.1.1`), why kernel-side filtering is orders of magnitude faster than userspace filtering.

**C++ patterns:**

- **Mutex-protected statistics** — Thread-safe aggregation with `std::mutex` and a lock-copy-return snapshot pattern that prevents data races without blocking the render thread.

- **Polymorphic IP parsing** — An abstract `IP_class` base with `IPv4` and `IPv6` subclasses, constructed from raw packet bytes and dispatching transport-layer parsing in the constructor.

- **RAII for C resources** — Wrapping a C-style `pcap_t*` handle in `std::unique_ptr<pcap_t, decltype(&pcap_close)>` so the handle is released automatically regardless of how the function exits.

- **FTXUI event loop threading** — Running packet capture in a background thread while FTXUI manages its own event loop on the main thread, coordinated with atomics and a shared render mutex.

## Prerequisites

**Required:**

- **C++20 basics** — You need to read code using structured bindings, `std::format`, ranges, `std::atomic`, and lambdas. If `auto [key, val] : map` looks unfamiliar, review modern C++ first.

- **TCP/IP networking** — Know the Ethernet → IP → TCP/UDP layer stack. Understand what IP addresses and port numbers are, what a three-way handshake does, how ICMP differs from TCP.

- **Linux command line** — You'll run commands, inspect network interfaces with `ip link`, and grant capabilities with `setcap`. Basic shell navigation assumed.

**Tools you'll need:**

- **Linux (Ubuntu/Debian/Arch/Fedora)** — The capture engine uses Linux-specific headers (`netinet/tcp.h`, `netinet/ip.h`). macOS will work with minor changes; Windows will not.

- **Root or CAP_NET_RAW** — Packet capture requires this. Either run with `sudo` or grant the binary the capability: `sudo setcap cap_net_raw,cap_net_admin=eip ./network-traffic-analyzer`.

- **libpcap, Boost, Ninja, CMake** — Handled by `install.sh`.

**Helpful but not required:**

- **Wireshark experience** — If you've read pcap files or written BPF display filters, you'll recognize the concepts immediately. Not necessary to build the project.

- **Systems programming background** — Understanding virtual dispatch, vtables, and pointer arithmetic at the byte level will help you follow `IP.cpp`. Not required but accelerates comprehension.

## Quick Start

```bash
# Clone the repo
git clone https://github.com/CarterPerez-dev/Cybersecurity-Projects.git
cd PROJECTS/beginner/network-traffic-analyzer/cpp

# Install dependencies and build (one command)
./install.sh

# List available interfaces
just interfaces

# Live capture on eth0
just capture -i eth0

# Capture 100 packets and export
just run -i wlan0 -c 100 --json result.json

# Analyze a pcap file offline
just run --offline traffic.pcap

# Run clang-tidy static analysis
just lint

# Auto-format all source files
just format
```

Expected output: the TUI launches full-screen, showing a live-updating table of transport protocols, application protocols, top IPs, top source→destination pairs, and a bandwidth graph. Press `q` or `Escape` to exit. On exit, results export to JSON/CSV if flags were passed.

## Project Structure

```
cpp/
├── main.cpp                     # Entry point — arg parsing, TUI setup, thread coordination
├── CMakeLists.txt               # Build definition
├── CMakePresets.json            # Debug/release presets with compile_commands.json export
├── Justfile                     # Dev commands (build, run, lint, format, clean)
├── install.sh                   # One-command setup: deps + build
├── .clang-tidy                  # Static analysis config
├── .clang-format                # Code style config
├── include/
│   ├── capture/pcapCapture.hpp  # PcapCapture — libpcap wrapper
│   ├── cli/
│   │   ├── argsParse.hpp        # argsParser — Boost.Program_options wrapper
│   │   └── filter.hpp           # filter struct + filter_type enum
│   ├── packet/
│   │   ├── packet.hpp           # Packet struct, protocol enums
│   │   └── IP.hpp               # IP_class, IPv4, IPv6 declarations
│   ├── stats/protocolStats.hpp  # Stats class, StatsSnapshot, all stat structs
│   └── TUI/view.hpp             # View — FTXUI renderer
└── src/
    ├── capture/pcapCapture.cpp  # Capture engine implementation
    ├── cli/
    │   ├── argsParse.cpp        # CLI option definitions
    │   └── filter.cpp           # BPF filter builder
    ├── packet/
    │   ├── packet.cpp           # Application protocol identification
    │   └── IP.cpp               # IPv4/IPv6 parsing implementation
    ├── stats/protocolStats.cpp  # Statistics aggregation, export
    └── TUI/view.cpp             # TUI layout and rendering
```

## Next Steps

1. **Understand the concepts** — Read [01-CONCEPTS.md](./01-CONCEPTS.md) for how libpcap, BPF, and protocol parsing work at the kernel level
2. **Study the architecture** — Read [02-ARCHITECTURE.md](./02-ARCHITECTURE.md) for the threading model and component design
3. **Walk through the code** — Read [03-IMPLEMENTATION.md](./03-IMPLEMENTATION.md) for line-by-line walkthroughs of every major component
4. **Extend it** — Read [04-CHALLENGES.md](./04-CHALLENGES.md) for ideas on adding TCP stream reassembly, anomaly detection, and more

## Common Issues

**Permission denied:**
```
pcap_open_live failed: eth0: You don't have permission to capture on that device
```
Run with `sudo just run` or grant capabilities: `sudo setcap cap_net_raw,cap_net_admin=eip ./build/release/network-traffic-analyzer`

**No packets on wireless interface:**
Many Wi-Fi drivers don't pass all frames in managed mode. Try `lo` (loopback) first to verify the tool works, then try your wired interface.

**clang-tidy can't find compile_commands.json:**
Run `just build` (debug preset) first — it generates `build/debug/compile_commands.json` with `CMAKE_EXPORT_COMPILE_COMMANDS=ON`. The `just lint` command reads from `build/release/compile_commands.json`, so run a release build too if needed.
