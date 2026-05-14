# Implementation Details

## Core DNS Resolution Implementation

### Single Record Type Query (`resolver.py:191-209`)
```python
async def query_record_type(
    domain: str,
    record_type: RecordType,
    resolver: dns.asyncresolver.Resolver,
) -> list[DNSRecord]:
    records = []
    
    try:
        answers = await resolver.resolve(domain, record_type.value)
        
        for rdata in answers:
            value, priority = extract_record_value(rdata, record_type)
            records.append(
                DNSRecord(
                    record_type=record_type,
                    value=value,
                    ttl=answers.rrset.ttl,
                    priority=priority,
                )
            )
    except (dns.resolver.NXDOMAIN, dns.resolver.NoAnswer, 
            dns.resolver.NoNameservers):
        pass  # Return empty list for these
    except dns.exception.Timeout:
        pass  # Also return empty list
    
    return records
```

**Key design decisions:**

1. **Exceptions as control flow**: NXDOMAIN and NoAnswer aren't errors, they're valid responses. The function returns an empty list rather than raising.

2. **TTL from rrset**: `answers.rrset.ttl` gives the TTL for the entire resource record set. All records in an rrset have the same TTL.

3. **Value extraction delegated**: The `extract_record_value()` function handles type-specific parsing. This keeps the query logic clean.

### Multi-Type Concurrent Query (`resolver.py:213-250`)
```python
async def lookup(
    domain: str,
    record_types: list[RecordType] | None = None,
    nameserver: str | None = None,
    timeout: float = 5.0,
) -> DNSResult:
    if record_types is None:
        record_types = ALL_RECORD_TYPES
    
    resolver = create_resolver(nameserver, timeout)
    result = DNSResult(domain=domain, nameserver=nameserver)
    
    start_time = time.perf_counter()
    
    # Create all tasks upfront
    tasks = [
        query_record_type(domain, rt, resolver) for rt in record_types
    ]
    
    # Execute all concurrently
    query_results = await asyncio.gather(*tasks, return_exceptions=True)
    
    # Process results
    for i, query_result in enumerate(query_results):
        if isinstance(query_result, Exception):
            result.errors.append(f"{record_types[i]}: {query_result}")
        else:
            result.records.extend(query_result)
    
    result.query_time_ms = (time.perf_counter() - start_time) * 1000
    
    return result
```

**Why `return_exceptions=True`?**

Without this flag, if one query raises an exception, `asyncio.gather()` cancels all other tasks and re-raises. With the flag, exceptions are returned as values, allowing partial results.

**Timing measurement:**
`time.perf_counter()` provides high-resolution timing. The difference is multiplied by 1000 to get milliseconds.

### Reverse DNS Lookup (`resolver.py:253-290`)
```python
async def reverse_lookup(
    ip_address: str,
    nameserver: str | None = None,
    timeout: float = 5.0,
) -> DNSResult:
    resolver = create_resolver(nameserver, timeout)
    result = DNSResult(domain=ip_address, nameserver=nameserver)
    
    start_time = time.perf_counter()
    
    try:
        # resolve_address handles both IPv4 and IPv6
        answers = await resolver.resolve_address(ip_address)
        
        for rdata in answers:
            result.records.append(
                DNSRecord(
                    record_type=RecordType.PTR,
                    value=str(rdata.target).rstrip("."),
                    ttl=answers.rrset.ttl,
                )
            )
    except dns.resolver.NXDOMAIN:
        result.errors.append("No PTR record found")
    except dns.resolver.NoAnswer:
        result.errors.append("No answer from nameserver")
    except dns.resolver.NoNameservers:
        result.errors.append("No nameservers available")
    except dns.exception.Timeout:
        result.errors.append("Query timed out")
    except dns.exception.DNSException as e:
        result.errors.append(str(e))
    
    result.query_time_ms = (time.perf_counter() - start_time) * 1000
    
    return result
```

**PTR record details:**
Reverse DNS uses special `.in-addr.arpa` (IPv4) or `.ip6.arpa` (IPv6) zones. For IP `8.8.8.8`, the query is for `8.8.8.8.in-addr.arpa` (reversed octets).

The `resolve_address()` method handles this conversion automatically.

## DNS Trace Implementation

The trace function (`resolver.py:293-426`) is the most complex. It implements iterative resolution, querying each layer of the DNS hierarchy.

### Initialization (`resolver.py:298-314`)
```python
result = TraceResult(domain=domain)

try:
    name = dns.name.from_text(domain)
    rdtype = dns.rdatatype.from_text(record_type)
    
    # Hardcoded root server IPs
    root_servers = [
        ("a.root-servers.net", "198.41.0.4"),
        ("b.root-servers.net", "170.247.170.2"),
        ("c.root-servers.net", "192.33.4.12"),
    ]
    
    current_servers = root_servers
    current_zone = "."
```

**Why hardcode root servers?**
Bootstrapping problem. To resolve `a.root-servers.net`, you need a working DNS resolver. These IPs are essentially the "root of trust" for DNS.

### Main Query Loop (`resolver.py:316-420`)
```python
while True:
    server_name, server_ip = current_servers[0]
    
    try:
        # Build DNS query packet
        query = dns.message.make_query(name, rdtype)
        
        # Send UDP packet directly to server
        response = dns.query.udp(query, server_ip, timeout=3.0)
        
        rcode = response.rcode()
        
        if rcode != dns.rcode.NOERROR:
            result.error = f"DNS error: {dns.rcode.to_text(rcode)}"
            break
```

This uses low-level dnspython APIs:
- `dns.message.make_query()`: Build DNS query packet
- `dns.query.udp()`: Send packet via UDP

Unlike high-level `resolver.resolve()`, this gives full control over which server to query.

### Handling Answers (`resolver.py:329-348`)
```python
if response.answer:
    # We got the answer!
    for rrset in response.answer:
        for rdata in rrset:
            result.final_answer = str(rdata)
            break
    
    result.hops.append(
        TraceHop(
            zone=current_zone,
            server=server_name,
            server_ip=server_ip,
            response=f"{record_type}: {result.final_answer}",
            is_authoritative=True,
        )
    )
    break  # Done tracing
```

The `answer` section contains the actual answer. This only appears when querying authoritative nameservers.

### Following Referrals (`resolver.py:350-404`)
```python
if response.authority:
    ns_records = []
    
    # Extract NS records from authority section
    for rrset in response.authority:
        if rrset.rdtype == dns.rdatatype.NS:
            for rdata in rrset:
                ns_name = str(rdata.target).rstrip(".")
                ns_records.append(ns_name)
            
            # Get the zone these NS records are for
            new_zone = str(rrset.name).rstrip(".")
            if not new_zone:
                new_zone = "."
```

The `authority` section contains NS records pointing to the next layer in the hierarchy.

### Resolving Glue Records (`resolver.py:369-403`)
```python
# Check for glue records in additional section
glue_ips = {}
if response.additional:
    for rrset in response.additional:
        if rrset.rdtype == dns.rdatatype.A:
            for rdata in rrset:
                glue_ips[str(rrset.name).rstrip(".")] = rdata.address

# Build list of next servers to query
new_servers = []
for ns in ns_records:
    if ns in glue_ips:
        # Use glue record
        new_servers.append((ns, glue_ips[ns]))
    else:
        # Must resolve NS hostname separately
        try:
            answers = dns.resolver.resolve(ns, "A")
            for rdata in answers:
                new_servers.append((ns, rdata.address))
                break
        except dns.exception.DNSException:
            continue
```

**Glue records solve circular dependency:**
If querying `example.com` and the NS records point to `ns1.example.com`, you'd need to resolve `ns1.example.com` to get its IP. But to resolve that, you need to query... the same NS server. Glue records provide the IP directly.

## CLI Command Implementation

### Argument Parsing (`cli.py:70-87`)
```python
def parse_record_types(types_str: str) -> list[RecordType]:
    if types_str.upper() == "ALL":
        return list(ALL_RECORD_TYPES)
    
    types = []
    for t in types_str.upper().split(","):
        t = t.strip()
        try:
            types.append(RecordType(t))
        except ValueError:
            console.print(
                f"[yellow]Warning:[/yellow] Unknown record type '{t}', skipping"
            )
    
    return types if types else list(ALL_RECORD_TYPES)
```

This handles user input like `"A,MX,NS"` or `"all"`. Invalid types generate warnings but don't fail.

### Progress Indicators (`cli.py:146-154`)
```python
with Progress(
    SpinnerColumn(),
    TextColumn("[progress.description]{task.description}"),
    console=console,
    transient=True,
) as progress:
    progress.add_task(f"Querying {domain}...", total=None)
    result = asyncio.run(lookup(domain, record_types, server, timeout))
```

`transient=True` makes the spinner disappear after completion. `total=None` creates an indefinite spinner (we don't know query duration upfront).

### Batch File Processing (`cli.py:297-312`)
```python
domains = []
with open(file) as f:
    for line in f:
        line = line.strip()
        if line and not line.startswith("#"):
            domains.append(line)

if not domains:
    console.print("[yellow]Warning:[/yellow] No domains found in file")
    raise typer.Exit(0)
```

Simple file format:
- One domain per line
- `#` for comments
- Empty lines ignored

**Security note:** No input validation on domain names. This trusts file input. For user-generated files, add validation to prevent malicious input.

## Output Formatting Implementation

### Table Generation (`output.py:83-127`)
```python
def print_results_table(result: DNSResult) -> None:
    if not result.records:
        console.print(
            Panel(
                f"[yellow]No records found for {result.domain}[/yellow]",
                title="[yellow]Warning[/yellow]",
                border_style="yellow",
                expand=False,
            )
        )
        return
    
    table = Table(
        title="[bold]DNS Records[/bold]",
        box=box.ROUNDED,
        border_style="blue",
        row_styles=["", "dim"],  # Alternate row shading
        show_header=True,
        header_style="bold cyan",
    )
    
    table.add_column("Type", width=8, no_wrap=True)
    table.add_column("Value", style="green", min_width=30)
    table.add_column("TTL", justify="right", style="dim", width=8)
    
    for record in result.records:
        color = get_record_color(record.record_type)
        value = record.value
        
        # Add priority annotation for MX records
        if record.priority is not None:
            value = f"{value} [dim](priority: {record.priority})[/dim]"
        
        table.add_row(
            f"[{color}]{record.record_type}[/{color}]",
            value,
            format_ttl(record.ttl),
        )
    
    console.print(table)
```

**Rich formatting features:**
- `box=box.ROUNDED`: Rounded corners
- `row_styles=["", "dim"]`: Alternating row colors for readability
- `min_width=30`: Prevents column from being too narrow
- `justify="right"`: Right-align TTL column

### Tree Visualization (`output.py:266-310`)
```python
tree = Tree(
    "[bold blue]:globe_showing_americas: DNS Resolution Path[/bold blue]",
    guide_style="blue",
)

zone_nodes: dict[str, Any] = {}

for hop in result.hops:
    # Create zone node if not exists
    if hop.zone not in zone_nodes:
        if hop.zone == ".":
            zone_display = "[bold yellow][.] Root[/bold yellow]"
        elif hop.zone.endswith("."):
            zone_display = f"[bold yellow][{hop.zone}] TLD[/bold yellow]"
        else:
            zone_display = f"[bold yellow][{hop.zone}.] Authoritative[/bold yellow]"
        
        zone_node = tree.add(zone_display)
        zone_nodes[hop.zone] = zone_node
    else:
        zone_node = zone_nodes[hop.zone]
    
    # Add server under zone
    server_style = "green" if hop.is_authoritative else "cyan"
    server_branch = zone_node.add(
        f"[{server_style}]:arrow_right: {hop.server}[/{server_style}] "
        f"[dim]({hop.server_ip})[/dim]"
    )
    
    # Add response under server
    server_branch.add(f"[dim]{hop.response}[/dim]")

console.print(tree)
```

**Zone grouping:**
Multiple hops can query the same zone (trying different servers). The dict ensures one zone node with multiple server children.

### JSON Serialization (`output.py:379-410`)
```python
def results_to_json(results: list[DNSResult] | DNSResult) -> str:
    if isinstance(results, DNSResult):
        results = [results]
    
    data = []
    for result in results:
        record_data = [
            {
                "type": r.record_type.value,
                "value": r.value,
                "ttl": r.ttl,
                "priority": r.priority,
            } for r in result.records
        ]
        
        data.append({
            "domain": result.domain,
            "records": record_data,
            "errors": result.errors,
            "query_time_ms": round(result.query_time_ms, 2),
            "nameserver": result.nameserver,
        })
    
    # Single result: return object. Multiple: return array
    if len(data) == 1:
        return json.dumps(data[0], indent=2)
    
    return json.dumps(data, indent=2)
```

**Single vs batch output:**
Single domain query returns `{ domain, records }` while batch returns `[{ domain, records }, ...]`. This is more ergonomic for consumers.

## WHOIS Implementation

### WHOIS Lookup (`whois_lookup.py:60-119`)
```python
def lookup_whois(domain: str) -> WhoisResult:
    result = WhoisResult(domain=domain)
    
    try:
        w = whois.whois(domain)
        
        # Check if domain exists
        if w is None or (hasattr(w, "domain_name") and w.domain_name is None):
            result.error = "Domain not found or WHOIS data unavailable"
            return result
        
        # Extract available fields (not all present for all domains)
        result.registrar = w.registrar if hasattr(w, "registrar") else None
        result.creation_date = w.creation_date if hasattr(w, "creation_date") else None
        result.expiration_date = w.expiration_date if hasattr(w, "expiration_date") else None
        result.updated_date = w.updated_date if hasattr(w, "updated_date") else None
        
        # Handle status field (can be string or list)
        if hasattr(w, "status"):
            status = w.status
            if isinstance(status, str):
                result.status = [status]
            elif isinstance(status, list):
                result.status = status
            else:
                result.status = []
```

**WHOIS data inconsistency:**
Different TLD registries return different fields. The `python-whois` library normalizes somewhat, but we still need defensive `hasattr()` checks.

**Status field complexity:**
Some registries return a single status string, others return a list. Normalize to always use a list.

### Date Formatting (`whois_lookup.py:41-57`)
```python
def format_date(dt: datetime | list | None) -> str:
    if dt is None:
        return "[dim]-[/dim]"
    
    # Some registries return lists of datetimes
    if isinstance(dt, list):
        dt = dt[0] if dt else None
    
    if dt is None:
        return "[dim]-[/dim]"
    
    if isinstance(dt, datetime):
        return dt.strftime("%Y-%m-%d")
    
    return str(dt)
```

**Why list of datetimes?**
Some WHOIS servers include timezone-normalized versions. We take the first.

## Testing Implementation

### Async Test Setup (`test_resolver.py:1-20`)
```python
import pytest

from dnslookup.resolver import (
    ALL_RECORD_TYPES,
    DNSRecord,
    DNSResult,
    RecordType,
    TraceResult,
    batch_lookup,
    create_resolver,
    lookup,
    reverse_lookup,
    trace_dns,
)
```

Tests import from actual modules, not mocks. This tests real DNS queries.

### Testing Async Functions (`test_resolver.py:138-146`)
```python
class TestLookup:
    @pytest.mark.asyncio
    async def test_lookup_real_domain(self) -> None:
        result = await lookup("example.com", [RecordType.A])
        assert result.domain == "example.com"
        assert result.query_time_ms > 0
```

`@pytest.mark.asyncio` decorator allows async test functions. `pytest-asyncio` plugin handles event loop management.

### Testing Error Conditions (`test_resolver.py:148-156`)
```python
@pytest.mark.asyncio
async def test_lookup_nonexistent_domain(self) -> None:
    result = await lookup(
        "this-domain-definitely-does-not-exist-12345.com",
        [RecordType.A]
    )
    assert result.domain == "this-domain-definitely-does-not-exist-12345.com"
    assert len(result.records) == 0
```

**No mocking:** Uses a domain extremely unlikely to exist. More fragile than mocking but tests real behavior.

## Common Implementation Patterns

### Pattern 1: Exceptions to Results
```python
try:
    # Operation that might fail
    answers = await resolver.resolve(domain, record_type)
    # Process answers
except ExpectedException:
    # Convert to empty result
    return []
except UnexpectedException as e:
    # Log to errors list
    result.errors.append(str(e))
```

This keeps the API clean (no exceptions for expected failures) while preserving error information.

### Pattern 2: Defensive Attribute Access
```python
result.registrar = w.registrar if hasattr(w, "registrar") else None
```

WHOIS responses vary. Use `hasattr()` before accessing attributes that might not exist.

### Pattern 3: Type Narrowing with isinstance
```python
if isinstance(query_result, Exception):
    result.errors.append(f"{record_types[i]}: {query_result}")
else:
    result.records.extend(query_result)
```

`asyncio.gather(return_exceptions=True)` returns exceptions as values. Use `isinstance()` to distinguish.

### Pattern 4: Rich Formatting Delegation
```python
# Never mix business logic and formatting
# BAD:
def lookup(...):
    print(f"Querying {domain}")
    result = resolve(domain)
    print_table(result)
    return result

# GOOD:
def lookup(...):
    return resolve(domain)

# Caller handles formatting
result = lookup(domain)
print_table(result)
```

Keeps resolver reusable in non-CLI contexts.

## Performance Optimizations

### Concurrent Queries (`resolver.py:233-242`)

Sequential queries: `7 types × 50ms = 350ms`
Concurrent queries: `max(50ms) = 50ms`

7x speedup for multi-type queries.

### Batch Concurrency (`resolver.py:428-440`)
```python
tasks = [lookup(domain, record_types, nameserver, timeout) for domain in domains]
return await asyncio.gather(*tasks)
```

For 100 domains:
- Sequential: `100 × 50ms = 5000ms`
- Concurrent: `~200-500ms` (limited by DNS server rate limits)

10-25x speedup.

### No Caching Trade-off

Every query hits DNS. This means:
- **Slower**: No cache hits
- **More accurate**: Never stale data
- **Higher load**: More packets to DNS servers

For a reconnaissance tool, accuracy matters more than speed.

Next, see `04-CHALLENGES.md` for ways to extend this project.
