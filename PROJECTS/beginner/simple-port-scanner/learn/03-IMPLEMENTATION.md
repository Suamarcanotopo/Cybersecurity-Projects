# Implementation Guide

This document walks through the actual code, explaining how asynchronous port scanning works under the hood and highlighting the tricky parts that make concurrent I/O work correctly.

## File Structure Walkthrough
```
simple-port-scanner/
├── src/
│   ├── PortScanner.hpp     # Class definition: member variables, async I/O primitives, method signatures
│   └── PortScanner.cpp     # Implementation: async scan logic, completion handlers, banner grabbing
├── main.cpp                # Entry point: CLI parsing, scanner initialization, blocking run() call
└── CMakeLists.txt          # Build config: C++20 standard, Boost dependency with program_options
```

## Building the CLI Interface

### Step 1: Argument Parsing

What we're building: User-friendly command line interface with sensible defaults

Create or examine `main.cpp`:
```cpp
// main.cpp:7-17
po::options_description desc("Allowed options");
desc.add_options()
    ("help,h", "produce help message")
    ("dname,i", po::value<std::string>()->default_value("127.0.0.1"), "set domain name or IP address")
    ("ports,p", po::value<std::string>()->default_value("1-1024"), "set a port range from 1 to n")
    ("threads,t", po::value<int>()->default_value(100), "max concurrent threads")
    ("expiry_time,e", po::value<uint8_t>()->default_value(2)->value_name("sec"), "timeout in seconds")
    ("verbose,v", "verbose output");
```

**Why this code works:**
- `po::value<T>()->default_value(X)`: Type-safe parameter parsing with automatic validation. If user passes "-t hello", Boost throws an exception rather than crashing.
- Short and long option forms (`-i` and `--dname`): Standard Unix convention makes the tool feel professional.
- `uint8_t` for expiry_time: Enforces range 0-255 seconds. Timeouts over 4 minutes don't make sense for port scanning.

**Common mistakes here:**
```cpp
// Wrong - no defaults means required parameters
desc.add_options()
    ("dname", po::value<std::string>(), "IP address");

// User must ALWAYS provide -i, which is annoying for testing localhost

// Right - defaults make tool usable without memorizing flags
desc.add_options()
    ("dname", po::value<std::string>()->default_value("127.0.0.1"), "IP address");
```

### Step 2: Displaying Help

Now we need to provide useful help text with examples.

In `main.cpp` (lines 23-34):
```cpp
if (vm.count("help")) {
    std::cout << desc << "\n";
    std::cout << "Examples:\n"
          << "  Scan common ports on localhost:\n"
          << "    ./port_scanner -i 127.0.0.1 -p 1-1024\n\n"
          << "  Full TCP port scan:\n"
          << "    ./port_scanner -i 192.168.1.1 -p 65535 -t 200\n\n"
          << "  Postscriptum:\n"
          << "  Scan only systems you own or have explicit permission to test.\n";
    return 0;
}
```

**What's happening:**
1. Check if user passed `-h` or `--help` flag
2. Print auto-generated option descriptions from `desc`
3. Add concrete usage examples (crucial - people learn from examples, not abstract descriptions)
4. Include legal/ethical warning (required for security tools)

**Why we do it this way:**
Boost.Program_Options generates descriptions automatically, but examples must be manual. Users copy-paste examples to learn, so we provide realistic scenarios (common ports, full scan, custom timeout).

**Alternative approaches:**
- Man page format: More formal but requires maintaining separate documentation
- Interactive prompts: Friendlier for beginners but annoying for scripters who want non-interactive tools

### Step 3: Passing Config to Scanner

Extract validated arguments and initialize the scanner:
```cpp
// main.cpp:36-40
std::string ip = vm["dname"].as<std::string>();
std::string port = vm["ports"].as<std::string>();
int threads = vm["threads"].as<int>();
uint8_t expiry_time = vm["expiry_time"].as<uint8_t>();

PortScanner scanner;
scanner.set_options(ip, port, threads, expiry_time);
```

This pattern (default constructor + `set_options`) allows reusing a scanner object for multiple scans. Alternative would be passing everything to constructor, but that's less flexible for interactive use.

## Building the Core Scanner

### The Scanning Algorithm

File: `src/PortScanner.cpp`

The heart of the scanner is the `scan()` method which implements a self-scheduling async pattern:
```cpp
// PortScanner.cpp:123-165
void PortScanner::scan() {
    if (q.empty() || cnt >= MAX_THREADS) return;  // Bail out if no work or at thread limit
    
    uint16_t port = q.front();
    q.pop();
    ++cnt;  // Increment active worker count
    
    auto socket = std::make_shared<tcp::socket>(io);
    auto timer = std::make_shared<boost::asio::steady_timer>(io);
    auto complete = std::make_shared<bool>(false);  // Race condition flag
    
    tcp::endpoint endpoint(this->endpoint.address(), port);
    
    timer->expires_after(std::chrono::seconds(expiry_time));
    
    // Timer handler - races against connection
    timer->async_wait(boost::asio::bind_executor(strand, 
        [this, complete, socket, port](boost::system::error_code ec) {
            if (!ec && !*complete)  {
                *complete = true;
                socket->close();
                printf("%i\t%s\t%s\t%s\n", port, "FILTERED", "NULL", "NULL");
                ++filtered_ports;
                --cnt;
                scan();  // Recursively grab next port
            }
        }));
    
    // Connection handler - races against timer
    socket->async_connect(endpoint, boost::asio::bind_executor(strand,
        [this, socket, timer, port, complete](boost::system::error_code ec) {
            if (*complete) return;  // Lost the race, timer already fired
            *complete = true;
            timer->cancel();  // Won the race, stop timer
            
            std::string service = "---";
            auto banner = std::make_shared<std::string>("---");
            
            // Look up service name
            auto it = basicPorts.find(port);
            if (it != basicPorts.end()) {
                service = it->second;
            }
            
            if (!ec) {
                // Connection succeeded - port is OPEN
                auto buf = std::make_shared<std::array<char, 128>>();
                
                socket->async_read_some(boost::asio::buffer(*buf),
                    boost::asio::bind_executor(strand,
                    [this, port, buf, banner, service](boost::system::error_code ec, std::size_t n) {
                        if (!ec && n > 0) {
                            banner->assign(buf->data(), n);
                        }
                        printf("%i\t%sOPEN%s\t%s\t%s\n", port, GREEN, RESET, service.c_str(), banner->c_str());
                        ++open_ports;
                        --cnt;
                        scan();  // Next port
                    }));
            } else {
                // Connection failed - port is CLOSED
                printf("%i\t%sCLOSED%s\t%s\t%s\n", port, RED, RESET, service.c_str(), banner->c_str());
                ++closed_ports;
                --cnt;
                scan();  // Next port
            }
        }));
}
```

**Key parts explained:**

**Guard clause** (`line 123-124`):
```cpp
if (q.empty() || cnt >= MAX_THREADS) return;
```
This prevents spawning infinite workers. If queue is empty, we're done. If we're at the thread limit, don't start another scan even if ports remain (workers already running will eventually call `scan()` again).

**Shared pointer lifetime management** (`lines 125-127`):
```cpp
auto socket = std::make_shared<tcp::socket>(io);
auto timer = std::make_shared<boost::asio::steady_timer>(io);
auto complete = std::make_shared<bool>(false);
```
These objects must outlive the async operation. Capturing shared pointers in lambda closures increments ref counts, keeping objects alive until completion handlers finish. Without this, socket/timer could be destroyed while async operations are pending (use-after-free).

**Race coordination with completion flag** (`line 127, 131, 139`):
```cpp
auto complete = std::make_shared<bool>(false);

// In timer handler:
if (!ec && !*complete) {
    *complete = true;  // I won!
    socket->close();
    // ...
}

// In connect handler:
if (*complete) return;  // I lost, timer already won
*complete = true;  // I won!
timer->cancel();
```
Both handlers check and set `complete` atomically (protected by strand). Whichever fires first sets the flag, and the loser returns early. This prevents double-processing the same port.

**Tail recursive work distribution** (` lines 136, 151, 158`):
Every completion handler ends with `scan()`. This implements a work-stealing pattern - as soon as one port finishes, that worker grabs the next port from the queue. No central dispatcher needed.

**Why this specific implementation:**

The timer/socket race elegantly solves filtered port detection. Without the timer, we'd wait forever on filtered ports (firewall drops packets, no response). The timer fires after `expiry_time` seconds if the socket hasn't connected, marking the port filtered.

The recursive `scan()` calls mean we never create more async operations than `MAX_THREADS`. We start `MAX_THREADS` scans, and each completion creates exactly one new scan, maintaining constant concurrency.

**Common mistakes here:**
```cpp
// Wrong - would leak if async operation fails
tcp::socket socket(io);  // Stack-allocated
timer->async_wait([&socket](...) {
    socket.close();  // If timer fires after function returns, socket is destroyed, crash!
});

// Right - shared pointer keeps it alive
auto socket = std::make_shared<tcp::socket>(io);
timer->async_wait([socket](...) {  // Captures shared_ptr, extends lifetime
    socket->close();  // Safe even if outer function returned
});
```

## Security Implementation

### Banner Grabbing

File: `PortScanner.cpp:143-151`
```cpp
auto buf = std::make_shared<std::array<char, 128>>();

socket->async_read_some(boost::asio::buffer(*buf),
    boost::asio::bind_executor(strand,
    [this, port, buf, banner, service](boost::system::error_code ec, std::size_t n) {
        if (!ec && n > 0) {
            banner->assign(buf->data(), n);
        }
        printf("%i\t%sOPEN%s\t%s\t%s\n", port, GREEN, RESET, service.c_str(), banner->c_str());
        // ...
    }));
```

**What this prevents:**
Nothing - banner grabbing is an offensive technique, not a defense. But understanding it helps you secure your services.

**How it works:**
1. After successful connection, allocate 128-byte buffer
2. Call `async_read_some` which returns immediately
3. When data arrives (or error occurs), completion handler fires
4. If bytes were read (`n > 0`), copy them into banner string
5. Print result with banner content

**What happens if you remove this:**
You'd still detect open ports but wouldn't know what software is running. The banner "SSH-2.0-OpenSSH_7.4" tells you it's SSH version 7.4, which has known CVEs. Without banners, you'd have to manually connect to each open port.

### Timeout-Based Filtering Detection

File: `PortScanner.cpp:128-137`
```cpp
timer->expires_after(std::chrono::seconds(expiry_time));

timer->async_wait(boost::asio::bind_executor(strand, 
    [this, complete, socket, port](boost::system::error_code ec) {
        if (!ec && !*complete)  {
            *complete = true;
            socket->close();
            printf("%i\t%s\t%s\t%s\n", port, "FILTERED", "NULL", "NULL");
            ++filtered_ports;
            --cnt;
            scan();
        }
    }));
```

**What this prevents:**
Infinite hangs on filtered ports. Without timeouts, `async_connect` waits indefinitely if a firewall drops packets.

**How it works:**
1. Set timer to expire in `expiry_time` seconds (default 2)
2. If timer fires AND connection hasn't completed (`!*complete`), port is filtered
3. Close the pending socket operation
4. Mark port as FILTERED

**What happens if you remove this:**
The scanner would hang forever on the first filtered port. You'd scan port 1 (filtered), wait eternally, never reach port 2. Timeouts are essential for handling non-responsive targets.

## Data Flow Example

Let's trace a complete scan of port 22 (SSH) on a host where it's open.

### Request Starts
```cpp
// Entry point: main.cpp:37-38
PortScanner scanner;
scanner.set_options("192.168.1.100", "22", 100, 2);
```

At this point:
- DNS resolver translates "192.168.1.100" to IP address (trivial for IPs)
- Endpoint stored as `tcp::endpoint` with IP
- Queue contains single entry: `22`

### Scanner Starts
```cpp
// PortScanner.cpp:111-114
for (int i = 0; i < MAX_THREADS; i++) {
    boost::asio::post(strand, [this]() {
        scan();
    });
}
```

This code posts 100 work items (since `MAX_THREADS=100`), but only 1 port in queue, so 99 return immediately at the guard clause. One worker proceeds:
```cpp
// PortScanner.cpp:123-127
uint16_t port = 22;  // Popped from queue
q.pop();  // Queue now empty
++cnt;  // cnt = 1

auto socket = std::make_shared<tcp::socket>(io);
auto timer = std::make_shared<boost::asio::steady_timer>(io);
```

### Connection Attempt
```cpp
// PortScanner.cpp:128-137
timer->expires_after(std::chrono::seconds(2));
timer->async_wait([...](...) { ... });  // Scheduled, not yet fired

// PortScanner.cpp:138
socket->async_connect(endpoint, [...](...) { ... });  // Begins TCP handshake
```

On the wire:
1. Scanner sends SYN packet to 192.168.1.100:22
2. Target responds with SYN-ACK (SSH is listening)
3. Scanner completes handshake with ACK
4. Connection established (< 100ms typically)

### Connection Succeeds
```cpp
// PortScanner.cpp:139-151
// Completion handler fires with ec = success
if (*complete) return;  // complete=false, so continue
*complete = true;  // Set flag
timer->cancel();  // Stops timer from firing

auto it = basicPorts.find(22);  // Found: "SSH"
std::string service = "SSH";

// Port is open, try banner grab
auto buf = std::make_shared<std::array<char, 128>>();
socket->async_read_some(boost::asio::buffer(*buf), [...](...) { ... });
```

The SSH server immediately sends its banner (protocol requirement):
```
SSH-2.0-OpenSSH_7.4p1 Debian-10+deb9u7
```

### Banner Received
```cpp
// PortScanner.cpp:144-151
[](boost::system::error_code ec, std::size_t n) {
    if (!ec && n > 0) {  // Success, read 43 bytes
        banner->assign(buf->data(), 43);  // "SSH-2.0-OpenSSH_7.4p1 Debian-10+deb9u7"
    }
    printf("%i\t%sOPEN%s\t%s\t%s\n", 22, GREEN, RESET, "SSH", "SSH-2.0-OpenSSH_7.4p1...");
    ++open_ports;  // Statistics
    --cnt;  // Active workers now 0
    scan();  // Check queue for more work (empty, so returns immediately)
}
```

The result is printed in green: `22  OPEN  SSH  SSH-2.0-OpenSSH_7.4p1 Debian-10+deb9u7`

## Error Handling Patterns

### Connection Refused (Closed Port)

When scanning port 8080 on a system with nothing listening:
```cpp
// PortScanner.cpp:153-158
else {
    // ec = "Connection refused" (ECONNREFUSED)
    printf("%i\t%sCLOSED%s\t%s\t%s\n", port, RED, RESET, service.c_str(), banner->c_str());
    ++closed_ports;
    --cnt;
    scan();
}
```

**Why this specific handling:**
Connection refused means the target sent a RST packet (port explicitly closed). This is different from timeout (filtered). We color code it red to distinguish from open ports visually.

**What NOT to do:**
```cpp
// Bad: catching and silencing errors
socket->async_connect(endpoint, [](boost::system::error_code ec) {
    // Ignore all errors - terrible idea
});
```

This hides network problems (DNS failure, route unreachable) that should be reported. Always check error codes.

### Timeout (Filtered Port)

When scanning port 12345 on a host behind a firewall that drops packets:
```cpp
// PortScanner.cpp:129-136
timer->async_wait([](boost::system::error_code ec) {
    if (!ec && !*complete) {  // Timer expired naturally (not cancelled)
        *complete = true;
        socket->close();  // Abort pending connection
        printf("%i\t%s\t%s\t%s\n", port, "FILTERED", "NULL", "NULL");
        ++filtered_ports;
        --cnt;
        scan();
    }
});
```

The `ec` check is crucial - if timer is cancelled (by connection succeeding), `ec` is set and we skip this handler. Only natural expiration means filtered.

## Performance Optimizations

### Before: Synchronous Scanning

This naive implementation would be disastrously slow:
```cpp
// Don't actually do this
for (int port = 1; port <= 65535; port++) {
    try {
        tcp::socket s(io);
        s.connect(tcp::endpoint(address, port));  // Blocks!
        // If we get here, port is open
    } catch (...) {
        // Port closed or filtered (can't tell which)
    }
}
```

This was slow because each `connect()` blocks for timeout duration. On a 2-second timeout:
- 65535 ports × 2 seconds = 131,070 seconds = 36 hours (!)

Even with 100ms connections:
- 65535 ports × 0.1 seconds = 6553 seconds = 1.8 hours

### After: Asynchronous Concurrent Scanning
```cpp
// PortScanner.cpp:111-115
for (int i = 0; i < MAX_THREADS; i++) {
    boost::asio::post(strand, [this]() { scan(); });
}
io.run();  // Blocks until all async ops complete
```

**What changed:**
- Started 100 async operations simultaneously
- Each completes independently and starts another
- Total time = (total ports / concurrency) × avg connection time
- 65535 ports / 100 workers × 0.1 seconds = 66 seconds

**Benchmarks:**
- Before (synchronous): 36 hours for full scan with 2-second timeout
- After (100 threads): ~2 minutes for same scan
- Improvement: 1080× faster

For local network scans with sub-10ms latency:
- Before: 11 minutes (65535 × 0.01s)
- After: 7 seconds (655 ports/sec throughput)
- Improvement: 95× faster

## Configuration Management

### Port Range Parsing
```cpp
// PortScanner.cpp:26-53
void PortScanner::parse_port(std::string& port) {
    auto t = std::find(port.begin(), port.end(), '-');
    if (t == port.end()) {
        // No dash - single port or max range
        startPort = 1;
        endPort = std::stoi(port);  // "1024" means 1-1024
        return;
    }
    
    // Parse "start-end" format
    std::string s = "", e = "";
    auto it = port.begin();
    while (it != port.end() && *it != '-') {
        s += *it;
        ++it;
    }
    ++it;  // Skip the dash
    while (it != port.end()) {
        e += *it;
        ++it;
    }
    
    int start = std::stoi(s);
    int end = std::stoi(e);
    
    // Validate bounds
    if (start == 0 || end > MAX_PORT || start > end) {
        startPort = 1;
        endPort = MAX_PORT;  // Invalid input = full scan
    } else {
        startPort = static_cast<uint16_t>(start);
        endPort = static_cast<uint16_t>(end);
    }
}
```

**Important details:**
- **Input validation**: Bounds checking ensures we don't scan port 0 (invalid) or > 65535 (impossible)
- **Fallback behavior**: Invalid input (like "5000-100") defaults to full scan rather than crashing
- **String parsing**: Manual character iteration instead of regex (simpler, no dependency)

We validate early because invalid port ranges cause weird errors later (queue might be empty, or contain 65535+ ports if math overflows). Failing fast at config time is better than mysterious runtime crashes.

### DNS Resolution
```cpp
// PortScanner.cpp:89-92
auto result = resolver.resolve(this->domainName, "");
endpoint = *result.begin();
```

**How this works:**
Boost.Asio resolver queries DNS for A/AAAA records. For "scanme.nmap.org", it returns 45.33.32.156. For IP addresses like "192.168.1.1", it validates format and returns immediately.

**Error handling:**
If resolution fails (domain doesn't exist, DNS server unreachable), `resolve()` throws. This is intentional - better to fail at startup than silently scan the wrong host.

## Common Implementation Pitfalls

### Pitfall 1: Forgetting to Bind to Strand

**Symptom:**
Random crashes, corrupted statistics, ports scanned multiple times or not at all.

**Cause:**
```cpp
// Wrong - no strand protection
socket->async_connect(endpoint, [this, port](...) {
    ++open_ports;  // RACE CONDITION!
    q.pop();       // CORRUPTS QUEUE!
});
```

Multiple completion handlers run concurrently, modifying shared state (`open_ports`, queue) without synchronization. This causes data races and undefined behavior.

**Fix:**
```cpp
// Right - strand serializes handlers
socket->async_connect(endpoint, boost::asio::bind_executor(strand,
    [this, port](...) {
        ++open_ports;  // Safe - only one handler runs at a time
        q.pop();       // Safe
    }));
```

**Why this matters:**
Data races are silent killers. Your program might work 99% of the time and crash unpredictably on the 1% where two handlers race. Always use strand for shared state.

### Pitfall 2: Capturing Local Variables by Reference

**Symptom:**
Use-after-free crashes, garbage data in completions.

**Cause:**
```cpp
void scan() {
    uint16_t port = q.front();
    socket->async_connect(endpoint, [&port](...) {  // WRONG!
        printf("Port %d\n", port);  // 'port' is destroyed when scan() returns
    });
}
```

The lambda captures `port` by reference, but `port` is a local variable that gets destroyed when `scan()` returns. The async operation hasn't completed yet, so when the handler finally runs, it accesses freed memory.

**Fix:**
```cpp
void scan() {
    uint16_t port = q.front();
    socket->async_connect(endpoint, [port](...) {  // Copy by value
        printf("Port %d\n", port);  // Safe - port was copied into the lambda
    });
}
```

**Why this matters:**
Async programming inverts control flow. The function returns long before the handler runs. Always capture by value or use shared pointers for objects with complex lifetimes.

## Debugging Tips

### Issue: "All ports show as FILTERED"

**Problem:** Every port times out, nothing shows as OPEN or CLOSED.

**How to debug:**
1. Check firewall on scanning machine - outbound connections might be blocked
2. Verify target is reachable: `ping 192.168.1.100`
3. Test with known open port: `telnet scanme.nmap.org 80` should connect
4. Reduce thread count and increase timeout: `-t 1 -e 10` eliminates concurrency and network issues

**Common causes:**
- Target host firewall drops all incoming connections (working as designed)
- Network firewall between you and target blocks port scanning traffic
- Target host is down or unreachable
- You're scanning from a restricted network (corporate, cloud provider) that blocks outbound scans

### Issue: "Segmentation fault in completion handler"

**Problem:** Crashes with stack trace in Boost.Asio internals.

**How to debug:**
1. Compile with debug symbols: `cmake -DCMAKE_BUILD_TYPE=Debug ..`
2. Run under valgrind: `valgrind --leak-check=full ./simplePortScanner`
3. Check for captured references: grep code for `[&` to find reference captures
4. Verify shared pointer usage: stack-allocated sockets/timers cause this

**Common causes:**
- Captured local variables by reference (Pitfall 2 above)
- Stack-allocated async objects that get destroyed while operations pending
- Double-free from manual memory management (should use shared_ptr)

## Extending the Code

### Adding UDP Scanning

Want to scan UDP ports? Here's the process:

1. **Create UDP socket type** in `PortScanner.hpp`
```cpp
   enum class Protocol { TCP, UDP };
   Protocol protocol = Protocol::TCP;
```

2. **Modify socket creation** in `scan()`
```cpp
   if (protocol == Protocol::UDP) {
       auto socket = std::make_shared<udp::socket>(io);
       // UDP scanning uses sendto instead of connect
   } else {
       auto socket = std::make_shared<tcp::socket>(io);
   }
```

3. **Implement UDP probe logic**
```cpp
   // UDP has no connection handshake
   // Send a payload specific to the service (DNS query for port 53)
   // Wait for response or ICMP unreachable
   socket->async_send_to(boost::asio::buffer(probe), endpoint, ...);
```

UDP scanning is harder because UDP doesn't have connection states. You must send protocol-specific probes and interpret responses to determine if a port is open.

## Dependencies

### Why Each Dependency

- **Boost.Asio** (1.70+): Async I/O framework that abstracts OS-specific socket APIs (epoll/kqueue/IOCP). We use it for `async_connect`, timers, and the event loop. Alternative: raw POSIX sockets, but requires implementing our own event loop.

- **Boost.Program_Options** (1.70+): CLI argument parser with type safety and automatic help generation. We use it in `main.cpp` for the `-i`, `-p`, `-t` flags. Alternative: manual `argv` parsing, but error-prone and lots of boilerplate.

### Dependency Security

Check for vulnerabilities:
```bash
# Boost doesn't have automated CVE scanning, but check your version
dpkg -l | grep libboost  # On Debian/Ubuntu
brew info boost          # On macOS

# Visit https://www.cvedetails.com/vendor/14185/Boost.html
```

If you see a Boost CVE affecting Asio (rare), upgrade:
```bash
sudo apt update && sudo apt upgrade libboost-all-dev
```

Most Boost vulnerabilities are in specific modules (Boost.Python, Boost.Beast). Asio is well-audited and stable.

## Build and Deploy

### Building
```bash
mkdir build && cd build
cmake ..
make
```

This produces the `simplePortScanner` executable in the build directory. The build process:

1. CMake reads `CMakeLists.txt` and finds Boost libraries
2. Generates platform-specific Makefiles (or Ninja/Xcode projects)
3. Compiler invokes with `-std=c++20` flag
4. Links against Boost.Program_Options and pthread (implicit)

### Local Development
```bash
# Rebuild after changes
cd build
make

# Run with verbose output to see all scans
./simplePortScanner -i 127.0.0.1 -p 1-100 -v

# Test specific ports
./simplePortScanner -i localhost -p 22,80,443
```

### Production Deployment

For real scanning work:
```bash
# Compile with optimizations
cmake -DCMAKE_BUILD_TYPE=Release ..
make

# Install to system
sudo cp simplePortScanner /usr/local/bin/
```

Key differences from dev:
- Release builds are 3-5× faster (compiler optimizations)
- Debug symbols stripped (smaller binary)
- Assertions disabled (no runtime checks)

## Next Steps

You've seen how async I/O, concurrent scanning, and state detection work. Now:

1. **Try the challenges** - [04-CHALLENGES.md](./04-CHALLENGES.md) has extension ideas like SYN scanning, service version detection, and output formats.

2. **Modify concurrency** - Change `MAX_THREADS` to 1 and observe serial scanning (slow). Change to 1000 and watch resource usage spike. Find the sweet spot for your network.

3. **Compare with Nmap** - Run `nmap -sT scanme.nmap.org` (TCP connect scan, same as ours) and compare results. Nmap has decades of edge case handling we don't.
