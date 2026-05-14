# Challenges and Extensions

## Beginner Challenges

### Challenge 1: Add DNSSEC Validation

**Goal:** Verify DNSSEC signatures on DNS responses.

**Current State:** The tool retrieves records but doesn't validate signatures. Line `resolver.py:200-201` just fetches data without cryptographic verification.

**Implementation Tasks:**
1. Enable DNSSEC in resolver (`resolver.py:91-107`)
```python
   resolver = dns.asyncresolver.Resolver()
   resolver.use_edns(0, dns.flags.DO, 4096)  # Request DNSSEC records
```

2. Check RRSIG records in responses
3. Validate signatures against DNSKEY records
4. Walk chain of trust from root to target domain

**Resources:**
- RFC 4033, 4034, 4035 (DNSSEC specs)
- dnspython DNSSEC validation examples
- Test with `dnssec-tools.org` (signed domain)

**Security Impact:** Prevents accepting forged DNS responses. Critical for high-security environments.

### Challenge 2: Implement DNS Query Logging

**Goal:** Log all queries to a file for analysis.

**What to Log:**
- Timestamp
- Domain queried
- Record types requested
- DNS server used
- Response time
- Number of records returned

**Implementation:**
1. Create logger in `resolver.py:213-250`
2. Log before query: `logging.info(f"Querying {domain} for {record_types}")`
3. Log after query: `logging.info(f"Got {len(result.records)} records in {result.query_time_ms}ms")`
4. Add CLI flag: `--log-file queries.log`

**Analysis Ideas:**
- Which domains take longest to resolve?
- Which record types fail most often?
- Time series analysis of response times

**Security Application:** Detect reconnaissance by analyzing query patterns.

### Challenge 3: Add CSV Output Format

**Goal:** Export results to CSV for spreadsheet analysis.

**Current State:** JSON output exists (`output.py:379-410`), but CSV would be more useful for some workflows.

**Implementation:**
1. Add `results_to_csv()` function in `output.py`
2. Flatten nested structure:
```
   domain,record_type,value,ttl,priority,query_time_ms
   example.com,A,93.184.216.34,86400,,45.2
   example.com,MX,mail.example.com,3600,10,45.2
```
3. Handle multiple records per domain
4. Add `--csv` flag to commands

**Use Case:** Import into Excel/Google Sheets for analysis, sorting, filtering.

## Intermediate Challenges

### Challenge 4: Subdomain Enumeration

**Goal:** Discover subdomains through various techniques.

**Techniques to Implement:**

**1. Brute Force** (`cli.py:266-350` as starting point)
```python
common_subdomains = ['www', 'mail', 'ftp', 'admin', 'test', 'dev', 'staging']
for sub in common_subdomains:
    fqdn = f"{sub}.{domain}"
    result = await lookup(fqdn, [RecordType.A])
    if result.records:
        print(f"Found: {fqdn}")
```

**2. Certificate Transparency Logs**
Query crt.sh API for domains in SSL certificates:
```python
import requests
response = requests.get(f"https://crt.sh/?q=%.{domain}&output=json")
```

**3. DNS Zone Transfer** (AXFR)
```python
try:
    zone = dns.zone.from_xfr(dns.query.xfr(nameserver, domain))
    for name in zone:
        print(f"{name}.{domain}")
except:
    print("Zone transfer refused")
```

**Security Note:** Zone transfers are often blocked. Only test on domains you own.

**Real World:** Subdomain enumeration is first step in reconnaissance (MITRE T1590.002).

### Challenge 5: DNS Monitoring and Alerting

**Goal:** Continuously monitor domains and alert on changes.

**Architecture:**
```
Periodic Queries (every 5 min)
        ↓
Compare to Previous State
        ↓
Detect Changes
        ↓
Send Alerts (email/Slack/webhook)
```

**What to Monitor:**
- A/AAAA record changes (infrastructure moved)
- MX record changes (email routing modified)
- NS record changes (DNS provider changed)
- New/removed records

**Implementation:**
1. Store previous state in SQLite database
2. Query on schedule (use `schedule` library or cron)
3. Compare current vs previous
4. Trigger alerts on differences

**Security Application:** Detect DNS hijacking attempts. If NS records suddenly change, someone might have compromised the registrar account.

**Real Incident:** MyEtherWallet (2018) - BGP hijack changed DNS to point to phishing site. Monitoring would have detected this.

### Challenge 6: DNS Performance Analysis

**Goal:** Measure and visualize DNS resolver performance.

**Metrics to Track:**
- Query latency percentiles (p50, p95, p99)
- Success rate by record type
- Timeout frequency
- Resolver comparison (8.8.8.8 vs 1.1.1.1 vs ISP)

**Implementation:**
1. Extend `DNSResult` with more metrics
2. Query same domains from multiple resolvers
3. Store results in time-series database (InfluxDB)
4. Visualize with Grafana

**Add to `resolver.py`:**
```python
@dataclass
class DNSResult:
    # ... existing fields ...
    resolver_ip: str | None = None
    tcp_fallback: bool = False
    truncated: bool = False
```

**Analysis Questions:**
- Which resolver is fastest for your location?
- Does performance vary by time of day?
- Which domains have the longest resolution times?

## Advanced Challenges

### Challenge 7: DNS Tunnel Detection

**Goal:** Identify DNS tunneling for data exfiltration.

**DNS Tunneling Characteristics:**
- High volume of queries to a single domain
- Large TXT record queries/responses
- Unusual subdomain lengths
- Base64/hex-encoded subdomains
- Regular query intervals

**Implementation:**

**1. Entropy Analysis**
```python
import math
from collections import Counter

def calculate_entropy(subdomain: str) -> float:
    """High entropy suggests encoded data"""
    counter = Counter(subdomain)
    length = len(subdomain)
    return -sum((count/length) * math.log2(count/length) 
                for count in counter.values())

# Legitimate: www.example.com (low entropy)
# Tunneling: aGVsbG8=.attacker.com (high entropy)
```

**2. Query Volume Detection**
```python
# Track queries per domain
query_counts = defaultdict(int)

for domain in queries:
    query_counts[domain] += 1
    if query_counts[domain] > threshold:
        alert(f"Possible tunneling: {domain}")
```

**3. Subdomain Length Analysis**
```python
if len(subdomain) > 63:  # DNS label limit
    alert("Suspicious long subdomain")
```

**Real Malware:** Houdini worm, Feederbot, DNScat2 all use DNS tunneling.

**References:**
- CWE-406: Insufficient Control of Network Message Volume
- MITRE T1071.004: Application Layer Protocol: DNS

### Challenge 8: Passive DNS Database

**Goal:** Build a historical database of DNS resolutions.

**Architecture:**
```
DNS Queries (from monitoring/batch)
        ↓
Store in Database
        ↓
Query Historical Data
```

**Schema:**
```sql
CREATE TABLE dns_records (
    id INTEGER PRIMARY KEY,
    domain TEXT,
    record_type TEXT,
    value TEXT,
    ttl INTEGER,
    first_seen TIMESTAMP,
    last_seen TIMESTAMP,
    seen_count INTEGER
);

CREATE INDEX idx_domain ON dns_records(domain);
CREATE INDEX idx_value ON dns_records(value);
```

**Queries to Support:**
- When did example.com first resolve to 1.2.3.4?
- What domains have resolved to this IP?
- How often does this domain change IPs?

**Security Application:** Track malware C2 infrastructure. Malicious domains often change IPs frequently.

**Commercial Examples:** VirusTotal, PassiveTotal, Farsight DNSDB.

### Challenge 9: Real-time DNS Query Stream Analysis

**Goal:** Analyze live DNS query streams (from router/firewall logs).

**Input Sources:**
- pcap files from network captures
- Syslog from DNS servers
- Netflow/IPFIX data
- Cloud DNS query logs (AWS Route53, Google Cloud DNS)

**Detection Patterns:**

**1. DGA (Domain Generation Algorithm)**
```python
def is_dga(domain: str) -> bool:
    """DGA domains are often random-looking"""
    labels = domain.split('.')
    if len(labels) < 2:
        return False
    
    sld = labels[-2]  # second-level domain
    
    # High consonant ratio
    consonants = sum(1 for c in sld if c in 'bcdfghjklmnpqrstvwxyz')
    if consonants / len(sld) > 0.7:
        return True
    
    # No dictionary words
    # Low vowel ratio
    # High entropy
    
    return False
```

**2. Fast Flux Detection**
Many IPs for one domain, changing frequently:
```python
# Track A records over time
if len(unique_ips_for_domain) > 10 and avg_ttl < 300:
    alert("Possible fast flux")
```

**3. C2 Beaconing**
Regular periodic queries:
```python
# Calculate query intervals
intervals = [queries[i+1].time - queries[i].time 
             for i in range(len(queries)-1)]

# If intervals are suspiciously regular
if std_dev(intervals) < threshold:
    alert("Possible C2 beaconing")
```

**Tools to Study:** Zeek (formerly Bro), Suricata DNS analysis modules.

### Challenge 10: DNS Firewall / Sinkhole

**Goal:** Block malicious domains by serving fake responses.

**Architecture:**
```
Client Query
    ↓
Your DNS Server
    ↓
Check Blocklist
    ↓
If Blocked: Return 0.0.0.0
If Allowed: Forward to Upstream Resolver
```

**Implementation:**

**1. Basic DNS Server** (use `dnslib` library)
```python
from dnslib import DNSRecord, RR, QTYPE, A
from dnslib.server import DNSServer

class BlocklistResolver:
    def __init__(self, blocklist):
        self.blocklist = set(blocklist)
    
    def resolve(self, request, handler):
        qname = str(request.q.qname)
        
        if qname.rstrip('.') in self.blocklist:
            # Return sinkhole IP
            reply = request.reply()
            reply.add_answer(RR(qname, QTYPE.A, rdata=A("0.0.0.0")))
            return reply
        else:
            # Forward to real resolver
            return proxy_request(request)
```

**2. Blocklist Sources**
- Malware domain lists (abuse.ch)
- Phishing feeds (PhishTank)
- Ad/tracker lists (EasyList)
- Threat intel feeds

**3. Logging and Analytics**
- Track blocked query attempts
- Identify infected machines
- Measure effectiveness

**Real Products:** Pi-hole, AdGuard Home, Cisco Umbrella.

## Expert Challenges

### Challenge 11: DNS Amplification Attack Detection

**Goal:** Detect when your DNS server is being used for amplification attacks.

**Attack Pattern:**
1. Attacker sends queries with spoofed source IP (victim's address)
2. Your server sends large responses to victim
3. Victim gets flooded

**Detection Signals:**
```python
# 1. High volume from single IP
queries_per_ip = defaultdict(int)

# 2. Queries for large record types
if record_type in [RecordType.TXT, RecordType.ANY]:
    suspicious_count += 1

# 3. Responses much larger than queries
if response_size / query_size > 50:
    alert("High amplification factor")

# 4. No follow-up queries (victim doesn't actually want data)
if client_ip in one_shot_queries:
    alert("Possible spoofed source")
```

**Mitigation:**
- Rate limit queries per IP
- Disable ANY queries (RFC 8482)
- Response rate limiting (RRL)
- BCP38 filtering (prevent spoofed source IPs)

### Challenge 12: Custom DNS Record Types

**Goal:** Add support for newer/specialized record types.

**Record Types to Add:**

**CAA (Certification Authority Authorization)**
```python
# In resolver.py:24-33
class RecordType(StrEnum):
    # ... existing types ...
    CAA = "CAA"  # RFC 8659
```

Specifies which CAs can issue certificates for domain. Security-critical.

**SSHFP (SSH Fingerprint)**
```python
SSHFP = "SSHFP"  # RFC 4255
```

Publishes SSH server key fingerprints in DNS for verification.

**TLSA (DANE/TLSA)**
```python
TLSA = "TLSA"  # RFC 6698
```

DNS-based Authentication of Named Entities. Publishes TLS certificate hashes.

**DNSKEY, DS, RRSIG** (DNSSEC records)
For challenge 1 (DNSSEC validation).

### Challenge 13: Geographic DNS Analysis

**Goal:** Determine where DNS servers are located and analyze geographic distribution.

**Implementation:**

**1. GeoIP Lookup**
```python
import geoip2.database

reader = geoip2.database.Reader('GeoLite2-City.mmdb')

for nameserver_ip in result.nameserver_ips:
    response = reader.city(nameserver_ip)
    print(f"{nameserver_ip}: {response.city.name}, {response.country.name}")
```

**2. Latency-based Geolocation**
Ping from multiple vantage points, use speed-of-light calculations to estimate location.

**3. Anycast Detection**
If same IP resolves to different locations, it's anycast (like root servers, Google DNS, Cloudflare DNS).

**Security Analysis:**
- Is DNS infrastructure geographically diverse? (resilience)
- Are responses coming from unexpected countries? (hijacking)
- Latency analysis for optimal resolver selection

### Challenge 14: DNS Covert Channel Communication

**Goal:** Implement bidirectional communication over DNS (for research/education only).

**How It Works:**

**Client → Server (via queries)**
```
Encode message in subdomain:
aGVsbG8=.tunnel.attacker.com
```

**Server → Client (via responses)**
```
Encode response in TXT record:
"d29ybGQ="
```

**Implementation:**
```python
def encode_query(data: bytes, domain: str) -> str:
    """Encode data in subdomain"""
    encoded = base64.b64encode(data).decode()
    # Split into DNS labels (63 char max)
    labels = [encoded[i:i+63] for i in range(0, len(encoded), 63)]
    return '.'.join(labels) + '.' + domain

def decode_response(txt_record: str) -> bytes:
    """Decode data from TXT record"""
    return base64.b64decode(txt_record)
```

**Challenges:**
- DNS has size limits (512 bytes UDP, 4096 TCP)
- Must handle fragmentation
- Packet loss requires retransmission
- High latency (1-2s per request)

**Countermeasures to Study:**
- Entropy analysis (challenge 7)
- Query volume limits
- Subdomain length restrictions
- TXT record size monitoring

**Ethical Note:** Only test on infrastructure you own. DNS tunneling without authorization is illegal.

### Challenge 15: Build a Recursive DNS Resolver

**Goal:** Implement a full recursive resolver from scratch (like BIND, Unbound).

**What It Does:**
1. Accept queries from clients
2. Iterate through DNS hierarchy (like trace command)
3. Cache results
4. Return answers

**Core Components:**

**1. Cache**
```python
from functools import lru_cache
import time

class DNSCache:
    def __init__(self):
        self.cache = {}
    
    def get(self, key):
        if key in self.cache:
            value, expiry = self.cache[key]
            if time.time() < expiry:
                return value
        return None
    
    def set(self, key, value, ttl):
        self.cache[key] = (value, time.time() + ttl)
```

**2. Recursive Resolution** (extend `trace_dns()` from `resolver.py:293-426`)

**3. Server Loop**
```python
from dnslib.server import DNSServer

class RecursiveResolver:
    def resolve(self, request, handler):
        qname = str(request.q.qname)
        
        # Check cache
        cached = self.cache.get(qname)
        if cached:
            return cached
        
        # Perform recursive resolution
        result = trace_and_resolve(qname)
        
        # Cache result
        self.cache.set(qname, result, ttl=300)
        
        return result

resolver = RecursiveResolver()
server = DNSServer(resolver, port=5353)
server.start_thread()
```

**Challenges:**
- Handle CNAME chains
- Implement negative caching (NXDOMAIN)
- Deal with timeouts and retries
- DNSSEC validation
- Handle TCP fallback for large responses

**Testing:**
```bash
dig @localhost -p 5353 example.com
```

## Research Challenges

### Challenge 16: Machine Learning for Malicious Domain Detection

**Goal:** Train ML model to classify domains as malicious or benign.

**Features to Extract:**
- Domain length
- Character entropy
- N-gram frequencies
- Vowel/consonant ratio
- TLD (.com vs .xyz vs .tk)
- Registration age (from WHOIS)
- Subdomain count
- Historical IP changes
- ASN reputation

**Training Data:**
- Benign: Alexa/Majestic top sites
- Malicious: abuse.ch, PhishTank, malware feeds

**Models to Try:**
- Random Forest
- XGBoost
- Neural networks for sequence data

**Evaluation:**
- Precision/recall on test set
- False positive rate (critical for blocklists)
- Performance on DGA domains

**Challenge:** Low false positives while catching novel threats.

### Challenge 17: DNS Privacy Analysis

**Goal:** Measure information leakage from DNS queries.

**What Leaks:**
- Browsing history from query logs
- Location from resolver choice
- Device type from query patterns
- App usage from CDN queries

**Experiments:**

**1. Reconstruct Browsing Session**
Collect DNS queries for 1 hour. Can you infer:
- Which websites visited?
- Which apps used?
- User's interests/demographics?

**2. DNS Fingerprinting**
Different devices make different queries:
- Android queries android.googleapis.com
- iOS queries apple.com services
- Windows queries microsoft.com

**3. Correlation Attacks**
Even with DoH, timing analysis can reveal sites:
```python
# Time between query and HTTP request
# Query pattern (images, scripts, API calls)
# Size of responses
```

**References:**
- "The Effect of DNS on Tor's Anonymity" (research paper)
- CWE-201: Information Exposure Through Sent Data

### Challenge 18: Develop DNS Benchmarking Suite

**Goal:** Create comprehensive DNS performance testing toolkit.

**Benchmarks:**

**1. Latency**
- Measure p50, p95, p99 query latency
- Test from multiple geographic locations
- Compare resolvers (Google, Cloudflare, Quad9)

**2. Throughput**
- Queries per second capacity
- Concurrent query handling

**3. Reliability**
- Success rate over 24 hours
- NXDOMAIN handling
- Timeout frequency

**4. Privacy**
- Query minimization support (RFC 7816)
- DNSSEC validation
- DoH/DoT support

**5. Censorship Resistance**
- Are queries filtered?
- Are results manipulated?

**Tools to Build:**
- Automated test runner
- Result aggregation and visualization
- Historical tracking
- Alerting on degradation

**Public Service:** Publish results like [DNSPerf.com](https://www.dnsperf.com/)

## Wrap-Up

Each challenge builds specific skills:
- **Challenges 1-3**: Tool development, output formats
- **Challenges 4-6**: Security monitoring, performance analysis
- **Challenges 7-10**: Threat detection, defensive tools
- **Challenges 11-15**: Advanced DNS concepts, covert channels
- **Challenges 16-18**: Research, ML, measurement studies

**Next Steps:**
1. Pick challenges matching your skill level
2. Start with beginner challenges to learn codebase
3. Progress to security-focused intermediate challenges
4. Tackle advanced challenges for deep expertise

**Resources:**
- DNS RFCs (1034, 1035, and extensions)
- OWASP Testing Guide (DNS sections)
- MITRE ATT&CK Framework (T1590, T1071.004, T1584.002)
- DNSViz for visualizing DNSSEC
- Wireshark for packet analysis

Happy hacking! Remember: only test on systems you own or have explicit permission to test.
