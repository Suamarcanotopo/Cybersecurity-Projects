# Simple Port Scanner

## What This Is

A concurrent TCP port scanner written in C++ that probes target hosts to identify open, closed, and filtered ports. It uses asynchronous I/O to scan multiple ports simultaneously and attempts to grab service banners for fingerprinting.

## Why This Matters

Port scanning is the first step in almost every network security assessment and penetration test. Before you can exploit a system, you need to know what's listening. This tool teaches you how attackers enumerate network services and how defenders can detect such reconnaissance.

**Real world scenarios where this applies:**

- **Penetration testing initial reconnaissance** - Every pentest starts with port scans to map the attack surface. Tools like Nmap are standard, but understanding how they work under the hood makes you a better tester.

- **Security audit preparation** - Before a compliance audit (PCI-DSS, SOC 2), you need to verify which ports are exposed. Unexpected open ports often indicate shadow IT or misconfigurations that fail audits.

- **Incident response and threat hunting** - When investigating a breach, you scan internal networks to find backdoors, C2 channels, or lateral movement artifacts. Attackers often open non-standard ports for persistence.

## What You'll Learn

This project teaches you how network reconnaissance works at the TCP layer. By building it yourself, you'll understand:

**Security Concepts:**

- **Port states and their meanings** - The difference between open, closed, and filtered ports tells you about both the service and the firewall. Open means a service is listening, closed means nothing is there but the host responded, filtered means a firewall dropped your packets silently.

- **TCP connection mechanics** - Port scanning exploits the TCP three-way handshake. Understanding SYN, SYN-ACK, and RST packets is fundamental to network security.

- **Banner grabbing for fingerprinting** - Services often announce themselves (SSH version strings, HTTP server headers). This information helps attackers select exploits and helps defenders identify outdated software.

**Technical Skills:**

- **Asynchronous I/O programming** - Scanning tens of thousands of ports sequentially would take hours. This project uses async operations to probe hundreds of ports concurrently, completing full scans in seconds.

- **Concurrent programming patterns** - Managing multiple async operations with shared state requires careful coordination. You'll use strand executors and shared pointers to prevent race conditions.

- **Network socket programming** - Direct TCP socket operations teach you what happens below HTTP and other application protocols. This low-level knowledge is essential for network security work.

**Tools and Techniques:**

- **Boost.Asio for network I/O** - Industry standard async I/O library used in production systems. Learning Asio teaches you patterns applicable to any high-performance network application.

- **Timeout-based filtering detection** - Differentiating between closed ports (active rejection) and filtered ports (silent drop) requires timing analysis. This technique applies to firewall fingerprinting and IDS evasion.

## Prerequisites

Before starting, you should understand:

**Required knowledge:**

- **Basic C++ programming** - You need familiarity with classes, smart pointers (`std::shared_ptr`), and lambda functions. This project uses C++20 features like structured bindings.

- **Networking fundamentals** - Know what an IP address and port number are, understand the difference between TCP and UDP, and have a basic grasp of the TCP handshake (SYN, SYN-ACK, ACK).

- **Command line comfort** - You'll compile with CMake and run the scanner from the terminal. Basic familiarity with bash and build systems helps.

**Tools you'll need:**

- **CMake 3.31+** - Build system for C++ projects. Install via package manager (`apt install cmake` on Ubuntu, `brew install cmake` on macOS).

- **C++20 compiler** - GCC 10+, Clang 12+, or MSVC 2019+. The project uses C++20 standard library features.

- **Boost libraries** - Specifically Boost.Asio for async I/O and Boost.Program_options for CLI parsing. Install with `apt install libboost-all-dev` or `brew install boost`.

**Helpful but not required:**

- **Wireshark or tcpdump** - Packet capture tools let you see the actual TCP packets your scanner sends. Watching SYN packets fly helps understand what's happening on the wire.

- **Nmap familiarity** - If you've used Nmap before, you'll recognize concepts like SYN scans and service detection. This project implements simplified versions of those techniques.

## Quick Start

Get the project running locally:
```bash
# Clone and navigate
cd PROJECTS/beginner/simple-port-scanner

# Create build directory
mkdir build && cd build

# Configure and build
cmake ..
make

# Run the scanner on localhost
./simplePortScanner -i 127.0.0.1 -p 1-1024

# Scan specific ports with custom settings
./simplePortScanner -i scanme.nmap.org -p 80,443,8080 -t 50 -e 3
```

Expected output: A table showing port number, state (OPEN/CLOSED/FILTERED), service name if recognized, and any banner grabbed from the service. Open ports appear in green, closed in red.

## Project Structure
```
simple-port-scanner/
├── src/
│   ├── PortScanner.hpp      # Class definition, member variables, method signatures
│   └── PortScanner.cpp      # Core scanning logic, async operations, banner grabbing
├── main.cpp                 # Entry point, CLI argument parsing with boost::program_options
└── CMakeLists.txt           # Build configuration, dependencies (Boost)
```

## Next Steps

1. **Understand the concepts** - Read [01-CONCEPTS.md](./01-CONCEPTS.md) to learn about TCP port states, banner grabbing, and network reconnaissance techniques.

2. **Study the architecture** - Read [02-ARCHITECTURE.md](./02-ARCHITECTURE.md) to see how async I/O and concurrent scanning are designed.

3. **Walk through the code** - Read [03-IMPLEMENTATION.md](./03-IMPLEMENTATION.md) for a detailed explanation of the scanning algorithm and async patterns.

4. **Extend the project** - Read [04-CHALLENGES.md](./04-CHALLENGES.md) for ideas like UDP scanning, OS fingerprinting, and stealth techniques.

## Common Issues

**"boost/asio.hpp: No such file or directory"**
```
fatal error: boost/asio.hpp: No such file or directory
```
Solution: Install Boost development libraries. On Ubuntu/Debian: `sudo apt install libboost-all-dev`. On macOS: `brew install boost`. On Windows, download from boost.org and configure CMake with `-DBOOST_ROOT=C:\path\to\boost`.

**"Connection refused" on all ports**
```
1	CLOSED	---	---
22	CLOSED	SSH	---
80	CLOSED	HTTP	---
```
Solution: This is normal if scanning a machine with no services running. Try scanning `scanme.nmap.org` which has intentional open ports for testing, or scan your own machine after starting a web server (`python3 -m http.server 8000`).

**Scanner hangs or runs very slowly**
Solution: Your firewall might be rate-limiting you. Reduce the thread count (`-t 10` instead of default 100) and increase timeout (`-e 5`). Also ensure you're not scanning from a network that blocks outbound connections.

## Related Projects

If you found this interesting, check out:

- **packet-sniffer** - Captures and analyzes raw network packets. Port scanning makes more sense when you can see the SYN/ACK exchanges.
- **basic-firewall** - Implements rules to block port scans. Understanding both sides (scanning and blocking) gives you complete network security perspective.
