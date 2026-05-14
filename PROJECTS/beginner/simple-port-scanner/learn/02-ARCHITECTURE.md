# System Architecture

This document breaks down how the port scanner is designed and why asynchronous I/O with concurrent workers provides both speed and clarity.

## High Level Architecture
```
┌─────────────────────────────────────┐
│      Command Line Interface         │
│   (Boost.Program_Options Parser)    │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│        PortScanner Object           │
│   - Configuration Management        │
│   - Work Queue (ports to scan)      │
│   - Thread/Concurrency Control      │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│       Boost.Asio io_context         │
│    (Event Loop / Async Runtime)     │
└──────────────┬──────────────────────┘
               │
       ┌───────┴───────┐
       ▼               ▼
┌─────────────┐  ┌─────────────┐
│   Socket    │  │    Timer    │
│   (TCP      │  │  (Timeout   │
│ Connection) │  │  Detection) │
└─────────────┘  └─────────────┘
       │               │
       └───────┬───────┘
               ▼
       ┌───────────────┐
       │    Target     │
       │  Host:Port    │
       └───────────────┘
```

### Component Breakdown

**Command Line Interface (main.cpp)**
- Purpose: Parse user input and initialize the scanner with configuration
- Responsibilities: Validate arguments, set defaults, display help text and usage examples
- Interfaces: Creates and configures a `PortScanner` object, then calls `start()` and `run()`

**PortScanner Controller (PortScanner class)**
- Purpose: Orchestrate the scanning process and manage concurrent operations
- Responsibilities: Maintain work queue of ports to scan, enforce thread limits, track statistics (open/closed/filtered counts), provide result formatting
- Interfaces: Exposes `set_options()`, `start()`, and `run()` methods; internally uses Boost.Asio primitives

**Boost.Asio io_context**
- Purpose: Event loop that drives all async operations
- Responsibilities: Schedule async socket operations and timer callbacks, dispatch completion handlers when I/O completes, manage execution strand for thread safety
- Interfaces: Provides async_connect, async_read_some, and async_wait operations that our scanner uses

**Socket and Timer Pair**
- Purpose: Each port scan uses one socket (for connection) and one timer (for timeout)
- Responsibilities: Socket attempts TCP connection; timer races against socket to detect filtered ports
- Interfaces: Completion handlers fire when either socket connects/fails or timer expires

## Data Flow

### Primary Scanning Flow

Step by step walkthrough of what happens when you run `./simplePortScanner -i 192.168.1.1 -p 80-443`:
```
1. main.cpp:12-23 → Parse command line arguments
   Extracts IP (192.168.1.1), port range (80-443), thread count (default 100), timeout (default 2 sec)

2. main.cpp:37-40 → Initialize PortScanner
   Calls set_options() which resolves DNS to IP address endpoint

3. PortScanner.cpp:77-82 → setup_queue()
   Fills queue with ports 80, 81, 82, ... 443 (364 ports total)

4. PortScanner.cpp:109-115 → start()
   Posts MAX_THREADS work items to io_context via strand
   Each work item is a call to scan() function

5. main.cpp:41 → run()
   Calls io.run() which blocks until all async operations complete

6. PortScanner.cpp:123-165 → scan() (called MAX_THREADS times concurrently)
   Pops port from queue, creates socket and timer, races them
   
   IF timeout expires first (line 130-136):
       → Port is FILTERED
       → Print result, decrement counter, recursively call scan() for next port
   
   IF connection succeeds (line 144-151):
       → Port is OPEN
       → Try banner grab (async_read_some)
       → Print result with banner, decrement counter, call scan() again
   
   IF connection fails (line 153-158):
       → Port is CLOSED
       → Print result, decrement counter, call scan() again

7. When queue is empty → io.run() completes → main.cpp:117-120 prints summary
```

Example with code references:
```
1. User runs command → main() (main.cpp:6)
   Boost.Program_Options parses to variables

2. Variables → PortScanner.set_options() (PortScanner.cpp:85-95)
   DNS resolution happens: resolver.resolve(domainName, "")
   Stores endpoint for later use

3. PortScanner.start() → Fills queue, posts work (PortScanner.cpp:109-115)
   100 async scan() operations begin

4. Each scan() → Creates socket + timer pair (PortScanner.cpp:123-127)
   Both operations start simultaneously
   Whoever completes first cancels the other

5. Completion handler → Determines port state (PortScanner.cpp:129-165)
   Prints result, decrements active counter, calls scan() to grab next port from queue

6. Queue exhausted → io.run() returns (main.cpp:41)
   Final statistics printed
```

### Secondary DNS Resolution Flow

Before any port scanning happens, we resolve the domain name:
```
1. User provides "-i scanme.nmap.org" → stored as string
2. PortScanner.set_options() calls resolver.resolve(domainName, "")
3. Boost.Asio performs DNS lookup (A or AAAA record)
4. Result converted to tcp::endpoint with IP address
5. All subsequent connections use this cached endpoint
```

This happens synchronously at startup. If DNS fails, the program errors immediately before any scanning begins. For IP addresses (like 192.168.1.1), resolution is trivial and just validates format.

## Design Patterns

### Async I/O with Completion Handlers

**What it is:**
Non-blocking I/O where operations return immediately and callbacks fire when complete. Instead of waiting for a socket connection (which might take seconds), we start the operation and provide a function to call when it finishes.

**Where we use it:**
Every network operation in the scanner:
- `async_connect` for TCP connections (PortScanner.cpp:138)
- `async_read_some` for banner grabbing (PortScanner.cpp:143)
- `async_wait` for timeout detection (PortScanner.cpp:128)

**Why we chose it:**
Scanning 65,535 ports synchronously would take hours. Even at 100ms per port (fast local network), that's 1.8 hours. With async I/O and 100 concurrent operations, we complete in minutes. The pattern also scales - changing thread count is one parameter.

**Trade-offs:**
- Pros: Massive concurrency with few actual threads, efficient resource usage, scales to thousands of simultaneous operations
- Cons: More complex code flow (callbacks instead of linear logic), harder to debug (stack traces show async machinery), requires understanding of event loops

Example implementation:
```cpp
// PortScanner.cpp:138-165
socket->async_connect(endpoint, boost::asio::bind_executor(strand, 
    [this, socket, timer, port, complete](boost::system::error_code ec) {
        if (*complete) return;  // Timer already fired, ignore this
        *complete = true;
        timer->cancel();        // Stop the race, we won
        
        if (!ec) {
            // Connection succeeded - port is OPEN
            async_read_some(...);  // Try to grab banner
        } else {
            // Connection failed - port is CLOSED
            print_result(...);
        }
        scan();  // Tail recursion to get next port
    }
));
```

The lambda captures shared state (`socket`, `timer`, `complete` flag) and runs later when the connection attempt finishes. This non-linear flow enables concurrency.

### Work Queue with Fixed Concurrency

**What it is:**
A queue of pending work (ports to scan) with a fixed number of workers pulling from it. As each worker completes, it grabs the next item. This prevents spawning 65,535 threads and overwhelming the system.

**Where we use it:**
- Queue: `std::queue<uint16_t> q` (PortScanner.hpp:24) filled in `setup_queue()` (PortScanner.cpp:77-82)
- Concurrency limit: `MAX_THREADS` (default 100) controls how many scans run simultaneously
- Work grabbing: `scan()` pops from queue (PortScanner.cpp:123), processes, then calls itself recursively for next port

**Why we chose it:**
Simple to understand and implement. The queue naturally handles work distribution - no complex scheduling logic. When a scan finishes quickly (closed port), the worker immediately grabs another. Slow scans (open ports with banner grabs) don't block other ports.

**Trade-offs:**
- Pros: Easy to reason about, automatic load balancing, simple thread limit enforcement
- Cons: Not perfectly efficient (if last few ports are slow, workers sit idle), doesn't prioritize interesting ports

### Strand for Thread Safety

**What it is:**
A Boost.Asio construct that serializes handler execution. When multiple async operations complete, the strand ensures their handlers don't run simultaneously. This provides thread safety without explicit locks.

**Where we use it:**
```cpp
// PortScanner.hpp:23
boost::asio::strand<boost::asio::io_context::executor_type> strand{io.get_executor()};

// All async operations wrapped in bind_executor(strand, ...)
// PortScanner.cpp:111, 129, 139, 144
boost::asio::post(strand, [this]() { scan(); });
boost::asio::bind_executor(strand, [...](...) { ... });
```

**Why we chose it:**
Multiple completion handlers modify shared state (`cnt`, `q`, statistics counters). Without synchronization, race conditions corrupt data. The strand guarantees that even though 100 operations run concurrently, their completion handlers execute one at a time.

**Trade-offs:**
- Pros: Thread-safe without manual locks, no risk of deadlock, clean code without mutex management
- Cons: Slight performance cost from serialization (negligible for our workload), all handlers must be wrapped consistently

## Layer Separation

The scanner has three distinct layers:
```
┌────────────────────────────────────┐
│    Presentation Layer              │
│    - CLI parsing (main.cpp)        │
│    - Output formatting             │
│    - Color codes for terminal      │
└────────────────────────────────────┘
           ↓
┌────────────────────────────────────┐
│    Business Logic Layer            │
│    - PortScanner class             │
│    - Scanning algorithm            │
│    - State management (counters)   │
└────────────────────────────────────┘
           ↓
┌────────────────────────────────────┐
│    I/O Layer                       │
│    - Boost.Asio runtime            │
│    - Socket operations             │
│    - Timer operations              │
└────────────────────────────────────┘
```

### Why Layers?

Separation of concerns makes each component testable and replaceable:

- Want a GUI instead of CLI? Replace presentation layer, keep business logic.
- Want to switch from Boost.Asio to raw POSIX sockets? Replace I/O layer, business logic unchanged.
- Want to add different scan types (UDP, SYN scan)? Extend business logic without touching presentation.

### What Lives Where

**Presentation Layer (main.cpp):**
- Files: `main.cpp`
- Imports: Can import business logic (PortScanner class), uses Boost.Program_Options for CLI parsing
- Forbidden: Must not directly create sockets or timers, must not implement scanning logic

**Business Logic Layer (PortScanner class):**
- Files: `src/PortScanner.hpp`, `src/PortScanner.cpp`
- Imports: Can import I/O layer (Boost.Asio), cannot import presentation layer
- Forbidden: Must not handle command line parsing or output formatting (just returns data)

**I/O Layer (Boost.Asio):**
- Files: External library (Boost)
- Imports: Standard library, OS-level socket APIs
- Forbidden: No business logic about ports or scanning

This structure means main.cpp knows about PortScanner, PortScanner knows about Asio, but Asio doesn't know about scanning, and scanning doesn't know about CLI flags.

## Data Models

### Port Queue Entry
```cpp
// PortScanner.hpp:24
std::queue<std::uint16_t> q;
```

**Fields explained:**
- Just the port number (0-65535) stored as `uint16_t` to save memory
- Queue processed FIFO - ports scanned in order (80, 81, 82, ...)

**Relationships:**
- Populated by `parse_port()` which converts user input like "80-443" into individual port numbers
- Consumed by `scan()` which pops ports one at a time

### Scanner State
```cpp
// PortScanner.hpp:25-29
int cnt = 0;                // Active concurrent scans
int MAX_THREADS = 0;        // Concurrency limit
int open_ports = 0;         // Statistics
int closed_ports = 0;
int filtered_ports = 0;
```

**Fields explained:**
- `cnt`: How many `scan()` operations are currently in flight. Prevents spawning too many workers.
- `MAX_THREADS`: User-configurable limit on concurrency. Defaults to 100 in main.cpp:15.
- Statistics counters: Incremented as results come in, printed at the end for summary.

**Relationships:**
- `cnt` guards the work queue - if `cnt >= MAX_THREADS`, no more scans start even if queue has ports
- Statistics tracked per completion handler (PortScanner.cpp:135, 148, 156)

### Well-Known Ports Map
```cpp
// PortScanner.cpp:3-24
const std::unordered_map<uint16_t, std::string> PortScanner::basicPorts{
    {21, "FTP"},
    {22, "SSH"},
    {80, "HTTP"},
    {443, "HTTPS"},
    ...
};
```

**Fields explained:**
- Static constant mapping from port numbers to service names
- Used for display only - doesn't affect scanning logic

**Relationships:**
- Looked up in completion handler (PortScanner.cpp:142) to show service name instead of just port number
- Missing ports display as "---" (PortScanner.cpp:140)

## Security Architecture

### Threat Model

What we're protecting against:

1. **Accidental network disruption** - Scanning too aggressively could crash target systems or network equipment. Thread limits and timeouts prevent overwhelming targets.

2. **Legal liability** - Scanning networks you don't own is often illegal (CFAA in the US). The tool includes usage warnings to educate users about legal boundaries.

3. **IDS/IPS detection** - While not stealth-focused, the scanner can be configured with lower thread counts and longer timeouts to reduce detection likelihood.

What we're NOT protecting against (out of scope):

- **Detection avoidance** - This is a basic scanner. Advanced IDS will catch it. Stealth techniques (SYN scans, fragmentation, decoys) are out of scope for a beginner project.
- **Target system DoS** - We limit threads but don't implement sophisticated rate limiting or backoff. A misconfigured scan could still overwhelm a weak target.

### Defense Layers

The scanner itself is a reconnaissance tool, but understanding defense-in-depth helps users protect against being scanned:
```
Layer 1: Firewall (prevents scan completion)
    ↓
Layer 2: IDS (detects scan pattern)
    ↓
Layer 3: Rate limiting (slows attacker)
```

**Why multiple layers?**

If the firewall fails (misconfigured rule), IDS alerts the security team. If IDS misses the scan (evasion technique), rate limiting prevents rapid enumeration. Each layer compensates for failures in others.

## Configuration

### Environment Variables

This scanner uses command line arguments, not environment variables:
```bash
./simplePortScanner \
  -i TARGET          # IP or domain name (default: 127.0.0.1)
  -p PORT_RANGE      # "80" or "1-1024" or "22,80,443" (default: 1-1024)
  -t THREADS         # Max concurrent scans (default: 100)
  -e TIMEOUT         # Seconds to wait before marking filtered (default: 2)
  -v                 # Verbose output (not yet implemented)
  -h                 # Help message
```

### Configuration Strategy

**Development:**
Use low thread counts (`-t 10`) and small port ranges (`-p 80-100`) to test without overwhelming your network. Scan localhost to verify functionality.

**Production:**
Real scans use higher concurrency (`-t 200` or more) for speed. Adjust timeout based on network latency - local networks can use 1 second, internet scans need 3-5 seconds. Always get permission before scanning external hosts.

## Performance Considerations

### Bottlenecks

Where this system gets slow under load:

1. **Network latency dominates** - Even with high concurrency, you can't scan faster than the network round-trip time. On a 50ms latency connection, each port takes at least 50ms regardless of how many threads you use.

2. **DNS resolution is synchronous** - The initial `resolver.resolve()` call blocks. For domains with slow DNS, this delays scan start. Caching resolved IPs could help repeated scans.

### Optimizations

What we did to make it faster:

- **Asynchronous I/O**: The big win. Synchronous scanning of 10,000 ports at 100ms each = 16 minutes. Async with 100 threads = ~10 seconds.

- **Shared pointer optimization** (PortScanner.cpp:125-127): Socket and timer created as `std::shared_ptr`. Completion handlers capture these, ensuring lifetime management without manual cleanup.

### Scalability

**Vertical scaling:**
Increase MAX_THREADS (up to ~1000 before hitting file descriptor limits on most systems). More threads = more concurrent scans = faster completion, but with diminishing returns beyond network capacity.

**Horizontal scaling:**
Split IP ranges across multiple scanner instances. Scan 192.168.1.0/24 by running 4 instances each handling 64 IPs. This parallelizes the bottleneck (network latency) across machines.

## Design Decisions

### Decision 1: Connect Scan vs SYN Scan

**What we chose:**
Full TCP connect scan (complete three-way handshake)

**Alternatives considered:**
- SYN scan (half-open scan): Send SYN, read SYN-ACK, send RST instead of completing handshake
- ACK scan: Send ACK packet to detect firewall rules
- UDP scan: Send UDP packets to check non-TCP services

**Why we chose connect scan:**
SYN scanning requires raw sockets, which need root privileges on Linux. This adds deployment complexity and security risk. Connect scans work as unprivileged users and integrate cleanly with Boost.Asio's high-level API.

**Trade-offs:**
- Pros: No special privileges needed, simpler code, cross-platform (works on Windows/Linux/macOS), less likely to crash buggy network stacks
- Cons: Noisier (shows up clearly in logs as completed connections), slightly slower (full handshake vs SYN only), some systems log connect attempts differently than SYNs

### Decision 2: Timer-Based Filtering vs. ICMP Analysis

**What we chose:**
Use timeout duration to infer filtered ports

**Alternatives considered:**
- Listen for ICMP "port unreachable" messages to distinguish closed from filtered
- Send multiple probe types (SYN, ACK, FIN) and correlate responses

**Why we chose timeouts:**
ICMP listening requires raw sockets (again, root privileges). Packet filters often drop ICMP anyway, making it unreliable. Timeouts work everywhere and handle the common case (firewall silently drops packets) correctly.

**Trade-offs:**
- Pros: Works without privileges, handles filtered ports correctly, simple to implement
- Cons: Adds latency to scans (must wait full timeout), can't distinguish "filtered by firewall" from "network down", false positives if network is just slow

### Decision 3: Recursive scan() vs. Worker Pool

**What we chose:**
Recursive tail calls to `scan()` for work distribution

**Alternatives considered:**
- Pre-spawn N worker threads that loop pulling from queue
- Use a thread pool library with work stealing

**Why we chose recursion:**
Fits naturally with async completion handlers. When a scan finishes, the completion handler just calls `scan()` again. The Boost.Asio event loop handles the scheduling.

**Trade-offs:**
- Pros: Minimal code, no manual thread management, automatic work distribution
- Cons: Stack depth increases (though tail call optimization helps), less control over worker lifecycle, harder to implement advanced scheduling

## Next Steps

Now that you understand the architecture:

1. Read [03-IMPLEMENTATION.md](./03-IMPLEMENTATION.md) for detailed code walkthrough showing how async operations coordinate
2. Try modifying the concurrency model - what happens if you remove the strand? (Race conditions will corrupt counters)
3. Experiment with timeout values to see how network latency affects scan duration
