# Architecture and Design

## System Architecture

The DNS lookup tool follows a clean three-layer architecture:
```
┌─────────────────────────────────────────────┐
│          User Interface Layer               │
│  (CLI commands, argument parsing)           │
│                                             │
│  File: cli.py                               │
│  Framework: Typer + Rich                    │
└──────────────┬──────────────────────────────┘
               │
               ├─> query()
               ├─> reverse()
               ├─> trace()
               ├─> batch()
               └─> whois()
               │
┌──────────────▼──────────────────────────────┐
│         Business Logic Layer                │
│  (DNS resolution, data processing)          │
│                                             │
│  Files: resolver.py, whois_lookup.py        │
│  Library: dnspython                         │
└──────────────┬──────────────────────────────┘
               │
               ├─> DNS Protocol (UDP:53)
               ├─> WHOIS Protocol (TCP:43)
               │
┌──────────────▼──────────────────────────────┐
│         Presentation Layer                  │
│  (Output formatting, visualization)         │
│                                             │
│  File: output.py                            │
│  Library: Rich                              │
└─────────────────────────────────────────────┘
```

This separation allows:
- Testing business logic without CLI
- Switching output formats without changing resolution logic
- Adding new commands without modifying core resolver

## Data Flow Architecture

### Single Domain Query Flow
```
User: dnslookup query example.com
            │
            ▼
    cli.py:112-167 (query command)
            │
            ├─> Parse arguments
            ├─> parse_record_types() → [A, AAAA, MX, ...]
            │
            ▼
    resolver.py:213-250 (lookup function)
            │
            ├─> create_resolver() → dns.asyncresolver.Resolver
            ├─> Start timer
            ├─> Create tasks for each record type
            │
            ▼
    resolver.py:191-209 (query_record_type)
            │
            ├─> await resolver.resolve(domain, "A")
            ├─> await resolver.resolve(domain, "AAAA")
            ├─> ... (parallel execution)
            │
            ▼
    asyncio.gather() → collect results
            │
            ▼
    DNSResult object (records + metadata)
            │
            ▼
    output.py:83-127 (print_results_table)
            │
            └─> Rich Table → Terminal
```

### Batch Query Flow
```
User: dnslookup batch domains.txt
            │
            ▼
    cli.py:266-350 (batch command)
            │
            ├─> Read file line by line
            ├─> Filter comments and empty lines
            │
            ▼
    resolver.py:428-440 (batch_lookup)
            │
            └─> [lookup(d1), lookup(d2), ..., lookup(dn)]
                      │
                      ▼
            asyncio.gather() → parallel execution
                      │
                      ▼
            [DNSResult, DNSResult, DNSResult, ...]
                      │
                      ▼
    output.py:340-377 (print_batch_results)
```

The key optimization: all domains queried concurrently (`resolver.py:432-440`).

### DNS Trace Flow
```
User: dnslookup trace example.com
            │
            ▼
    cli.py:219-263 (trace command)
            │
            ▼
    resolver.py:293-426 (trace_dns)
            │
            ├─> Start at root servers [.]
            │   └─> Query a.root-servers.net:198.41.0.4
            │       Response: "Refer to .com servers"
            │
            ├─> Query .com TLD server
            │   └─> Get NS records for example.com
            │       Response: "Refer to ns1.example.com"
            │
            ├─> Query authoritative server
            │   └─> ns1.example.com
            │       Response: "A 93.184.216.34" (answer!)
            │
            └─> Build TraceResult with hops
                      │
                      ▼
    output.py:266-310 (print_trace_result)
            └─> Rich Tree visualization
```

This mimics how a real recursive resolver operates.

## Core Data Structures

### RecordType Enum (`resolver.py:24-33`)
```python
class RecordType(StrEnum):
    A = "A"
    AAAA = "AAAA"
    MX = "MX"
    NS = "NS"
    TXT = "TXT"
    CNAME = "CNAME"
    SOA = "SOA"
    PTR = "PTR"
```

Using `StrEnum` provides type safety while allowing string comparison. The values match DNS protocol record type names exactly.

### DNSRecord Dataclass (`resolver.py:46-54`)
```python
@dataclass
class DNSRecord:
    record_type: RecordType
    value: str
    ttl: int
    priority: int | None = None
```

Represents a single DNS resource record. The `priority` field is `None` for most record types but populated for MX records (`resolver.py:148-150`).

### DNSResult Dataclass (`resolver.py:57-65`)
```python
@dataclass
class DNSResult:
    domain: str
    records: list[DNSRecord] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    query_time_ms: float = 0.0
    nameserver: str | None = None
```

Aggregates all information about a query. Using `field(default_factory=list)` prevents mutable default argument bugs.

### TraceHop and TraceResult (`resolver.py:68-88`)
```python
@dataclass
class TraceHop:
    zone: str              # ".", ".com", "example.com"
    server: str            # "a.root-servers.net"
    server_ip: str         # "198.41.0.4"
    response: str          # Human-readable response
    is_authoritative: bool # Final answer vs referral

@dataclass
class TraceResult:
    domain: str
    hops: list[TraceHop] = field(default_factory=list)
    final_answer: str | None = None
    error: str | None = None
```

Models the complete resolution path through DNS hierarchy.

## Component Interaction Patterns

### Resolver to Output Decoupling

The resolver never imports output. It returns data structures. The CLI layer calls both:
```python
# cli.py:155-167
result = asyncio.run(lookup(domain, record_types, server, timeout))

if json_output:
    console.print(results_to_json(result))
else:
    print_header(domain)
    print_results_table(result)
    print_errors(result)
    print_summary(result)
```

This allows:
- Different output formats (JSON, table, CSV)
- Testing resolver without terminal
- Using resolver in other projects

### Error Handling Strategy

The resolver catches exceptions and converts to error messages (`resolver.py:181-189`):
```python
except (dns.resolver.NXDOMAIN, dns.resolver.NoAnswer, 
        dns.resolver.NoNameservers):
    pass  # Expected, not an error
except dns.exception.Timeout:
    pass  # Also expected
```

Errors are accumulated in `DNSResult.errors` list rather than raising exceptions. This allows partial results (some record types succeed, others fail).

### Async Execution Model

The project uses `asyncio` throughout for I/O-bound DNS operations. Key pattern (`resolver.py:233-242`):
```python
tasks = [query_record_type(domain, rt, resolver) for rt in record_types]
query_results = await asyncio.gather(*tasks, return_exceptions=True)

for i, query_result in enumerate(query_results):
    if isinstance(query_result, Exception):
        result.errors.append(f"{record_types[i]}: {query_result}")
    else:
        result.records.extend(query_result)
```

`return_exceptions=True` prevents one failure from canceling other tasks.

## DNS Protocol Implementation

### Creating a Resolver (`resolver.py:91-107`)
```python
def create_resolver(
    nameserver: str | None = None,
    timeout: float = 5.0,
) -> dns.asyncresolver.Resolver:
    resolver = dns.asyncresolver.Resolver()
    resolver.timeout = timeout
    resolver.lifetime = timeout * 2  # Total query lifetime
    
    if nameserver:
        resolver.nameservers = [nameserver]
    
    return resolver
```

Two timeout values:
- `timeout`: Per-query timeout
- `lifetime`: Total time including retries

### Extracting Record Values (`resolver.py:110-158`)

Different record types have different response structures:
```python
if record_type == RecordType.A or record_type == RecordType.AAAA:
    value = rdata.address  # Simple IP string
elif record_type == RecordType.MX:
    value = str(rdata.exchange).rstrip(".")
    priority = rdata.preference  # MX-specific
elif record_type in (RecordType.NS, RecordType.CNAME, RecordType.PTR):
    value = str(rdata.target).rstrip(".")  # FQDN
```

The `.rstrip(".")` removes trailing dot from fully qualified domain names.

### Trace Implementation Deep Dive

The trace function (`resolver.py:293-426`) implements iterative DNS resolution. Key sections:

**1. Start at root servers** (`resolver.py:307-314`):
```python
root_servers = [
    ("a.root-servers.net", "198.41.0.4"),
    ("b.root-servers.net", "170.247.170.2"),
    ("c.root-servers.net", "192.33.4.12"),
]
current_servers = root_servers
current_zone = "."
```

**2. Query loop** (`resolver.py:318-420`):
Each iteration queries a server, processes the response, and follows referrals.

**3. Check for answer** (`resolver.py:329-348`):
```python
if response.answer:
    for rrset in response.answer:
        for rdata in rrset:
            result.final_answer = str(rdata)
            break
    # Record this hop as authoritative
    result.hops.append(TraceHop(..., is_authoritative=True))
    break  # Done!
```

**4. Follow referrals** (`resolver.py:350-404`):
```python
if response.authority:
    ns_records = []
    for rrset in response.authority:
        if rrset.rdtype == dns.rdatatype.NS:
            for rdata in rrset:
                ns_name = str(rdata.target).rstrip(".")
                ns_records.append(ns_name)
```

**5. Resolve glue records** (`resolver.py:374-403`):
Glue records provide IP addresses for nameservers to avoid circular dependencies.
```python
glue_ips = {}
if response.additional:
    for rrset in response.additional:
        if rrset.rdtype == dns.rdatatype.A:
            for rdata in rrset:
                glue_ips[str(rrset.name).rstrip(".")] = rdata.address
```

## Output Formatting Architecture

### Rich Console Integration

All output goes through a single console instance (`output.py:19`):
```python
console = Console()
```

This ensures consistent styling and supports color detection.

### Record Type Coloring (`output.py:22-32`)
```python
RECORD_COLORS: dict[RecordType, str] = {
    RecordType.A: "green",
    RecordType.AAAA: "blue",
    RecordType.MX: "magenta",
    RecordType.NS: "cyan",
    RecordType.TXT: "yellow",
    RecordType.CNAME: "red",
    RecordType.SOA: "white",
    RecordType.PTR: "bright_cyan",
}
```

Colors help visually distinguish record types in mixed-type queries.

### TTL Formatting (`output.py:45-61`)

Converts seconds to human-readable format:
```python
if ttl >= 86400:
    days = ttl // 86400
    return f"{days}d"
elif ttl >= 3600:
    hours = ttl // 3600
    return f"{hours}h"
```

This makes TTL values easier to understand at a glance.

### Tree Visualization for Traces (`output.py:266-310`)
```python
tree = Tree(
    "[bold blue]:globe_showing_americas: DNS Resolution Path[/bold blue]",
    guide_style="blue",
)

zone_nodes: dict[str, Any] = {}

for hop in result.hops:
    if hop.zone not in zone_nodes:
        zone_node = tree.add(zone_display)
        zone_nodes[hop.zone] = zone_node
    else:
        zone_node = zone_nodes[hop.zone]
    
    server_branch = zone_node.add(f"[{server_style}]:arrow_right: {hop.server}[/{server_style}]")
```

Groups hops by zone for clearer visualization.

## Configuration and Dependency Management

### Project Configuration (`pyproject.toml:1-36`)
```toml
[project]
name = "dnslookup-cli"
version = "0.1.1"
dependencies = [
    "dnspython>=2.8.0",   # DNS protocol library
    "rich>=14.2.0",       # Terminal formatting
    "typer>=0.20.0",      # CLI framework
    "python-whois>=0.9.6", # WHOIS lookups
]
```

Minimal dependencies keep the project lightweight.

### Development Tools (`pyproject.toml:38-45`)
```toml
[project.optional-dependencies]
dev = [
    "pytest>=8.0.0",
    "pytest-asyncio>=0.25.0",  # Test async code
    "pytest-cov>=6.0.0",       # Coverage reporting
    "ruff>=0.9.0",             # Linting
    "mypy>=1.15.0",            # Type checking
]
```

## Task Automation (justfile)

The justfile provides convenient commands (`justfile:17-150`):
```make
run *ARGS:
    uv run dnslookup {{ARGS}}

lookup domain *ARGS:
    uv run dnslookup {{domain}} {{ARGS}}

ci: lint typecheck test
```

This simplifies development workflow without requiring knowledge of `uv` syntax.

## Security Considerations in Architecture

**1. No persistent state**: Each query is independent
- Prevents cache poisoning
- No state to corrupt
- Simple to reason about

**2. Explicit DNS server selection**: User controls which resolver to trust
- Can test against authoritative nameservers
- Useful for validating DNS propagation

**3. Timeout enforcement**: Network operations can't hang indefinitely
- `timeout` per query (`resolver.py:99`)
- `lifetime` for total operation (`resolver.py:100`)

**4. Error transparency**: All errors surfaced to user
- No silent failures
- User can investigate issues

**5. No local caching**: Fresh data every query
- Prevents stale data issues
- Higher load but more accurate

Next, see `03-IMPLEMENTATION.md` for detailed code walkthroughs.
