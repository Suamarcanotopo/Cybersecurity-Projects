# DNS Concepts and Security Implications

## DNS Protocol Fundamentals

DNS (Domain Name System) is a distributed hierarchical database that translates human-readable domain names into IP addresses. Understanding DNS deeply is critical for both defending networks and understanding attack vectors.

### The DNS Hierarchy
```
                          [Root Servers]
                         a-m.root-servers.net
                               |
                    +----------+----------+
                    |                     |
              [.com TLD]              [.org TLD]
           TLD nameservers         TLD nameservers
                    |                     |
              +-----+-----+               |
              |           |               |
         [example.com] [google.com]  [example.org]
      Authoritative NS  Authoritative NS
```

The trace command (`dnslookup/resolver.py:293-426`) implements walking this hierarchy. It starts at root servers (`resolver.py:307-312`):
```python
root_servers = [
    ("a.root-servers.net", "198.41.0.4"),
    ("b.root-servers.net", "170.247.170.2"),
    ("c.root-servers.net", "192.33.4.12"),
]
```

These 13 logical root server addresses (actually hundreds of physical servers via anycast) are hardcoded into every DNS resolver.

### DNS Record Types

The project supports eight record types (`dnslookup/resolver.py:24-33`):

**A Record (IPv4 Address)**
- Maps domain to 32-bit IPv4 address
- Example: `example.com → 93.184.216.34`
- Security note: Can be hijacked to redirect traffic

**AAAA Record (IPv6 Address)**
- Maps domain to 128-bit IPv6 address
- Attackers increasingly target IPv6 due to less monitoring

**MX Record (Mail Exchanger)**
- Specifies mail servers for a domain
- Has priority field (`resolver.py:148-150`)
- Security: Reveals email infrastructure, can be spoofed for phishing

**NS Record (Name Server)**
- Delegates a zone to specific DNS servers
- Critical for understanding DNS hierarchy
- Attackers target these for DNS hijacking

**TXT Record (Text Data)**
- Arbitrary text, often used for:
  - SPF (email sender verification)
  - DKIM (email signing)
  - Domain verification
  - Sometimes abused for DNS tunneling

**CNAME Record (Canonical Name)**
- Alias from one domain to another
- Can create long chains that impact performance
- Security: Can be used to hide real infrastructure

**SOA Record (Start of Authority)**
- Contains zone metadata (`resolver.py:153`)
- Shows primary nameserver and serial number
- Reveals zone transfer configuration

**PTR Record (Pointer)**
- Reverse DNS mapping (IP → hostname)
- Used in email validation and logging
- Absence indicates poor infrastructure hygiene

### How DNS Resolution Works

When you query `www.example.com`, here's what happens (implemented in `resolver.py:293-426`):

1. **Query Root Server** (`resolver.py:319-328`)
   - Ask root server about `.com`
   - Root refers to `.com` TLD servers

2. **Query TLD Server** (`resolver.py:359-380`)
   - Ask TLD about `example.com`
   - TLD refers to authoritative nameservers

3. **Query Authoritative Server** (`resolver.py:329-348`)
   - Get the actual answer
   - Response marked authoritative

4. **Cache Result**
   - TTL field controls cache duration (`output.py:52-61`)
   - This project doesn't cache (fresh queries every time)

The trace function shows this visually (`output.py:266-310`).

## Security Concepts

### DNS Cache Poisoning (CVE-2008-1447, Kaminsky Attack)

DNS responses lack strong authentication. An attacker can:
1. Send query to victim's DNS server
2. Flood with forged responses before real answer arrives
3. If forged response arrives first and has correct transaction ID, it's cached

**Defenses:**
- DNSSEC (cryptographic signatures)
- Randomized source ports
- Transaction ID randomization

This tool doesn't implement DNSSEC validation but shows you raw DNS data to understand what could be spoofed.

### DNS Tunneling (MITRE T1071.004)

Exfiltrating data through DNS queries. An attacker might:
1. Encode stolen data in subdomain: `<base64-data>.attacker.com`
2. Their authoritative server logs all queries
3. Data extracted from DNS query logs

The TXT record support in this tool shows how much data can fit in DNS (`resolver.py:151-152`):
```python
elif record_type == RecordType.TXT:
    value = rdata.to_text()
```

TXT records can be 255 characters per string, multiple strings per record.

### DNS Reconnaissance (MITRE T1590.002)

Attackers use DNS to map infrastructure before attacks:
- A/AAAA records reveal IP addresses and hosting providers
- MX records show email infrastructure
- NS records expose DNS provider
- TXT records leak SPF/DKIM configurations

The batch command (`cli.py:266-350`) demonstrates automated reconnaissance at scale.

### DNS Amplification DDoS

Attacker sends small DNS queries with spoofed source IP (victim's address). DNS server sends large responses to victim. Amplification factor can be 50x.

**How to spot it:**
- Unusual query patterns
- High volume of ANY queries (deprecated)
- Queries for large TXT/DNSSEC records

### DNS Hijacking

Compromising DNS infrastructure to redirect traffic:
- **Registrar compromise**: Change nameserver records
- **Nameserver compromise**: Modify zone files
- **Cache poisoning**: Inject false records into resolvers
- **BGP hijacking**: Route DNS traffic to attacker

Real incidents:
- **Sea Turtle** (2019): Targeted government DNS infrastructure
- **MyEtherWallet** (2018): BGP hijack redirected to phishing site

## DNS Privacy Issues

Every DNS query is visible to:
1. Your ISP's DNS resolver
2. Authoritative nameservers
3. Any intermediate network

This reveals browsing history. Solutions:
- **DNS over HTTPS (DoH)**: Encrypts queries in HTTPS
- **DNS over TLS (DoT)**: Encrypts queries in TLS
- **DNSCrypt**: Encrypts and authenticates

This tool doesn't implement encryption but uses standard UDP port 53 queries.

## Time-to-Live (TTL) Security

TTL controls caching duration (`output.py:45-61`). Low TTL means:
- More queries hitting authoritative servers
- Faster propagation of changes
- Less opportunity for stale poisoned caches

High TTL means:
- Reduced load on DNS infrastructure
- Slower incident response
- Poisoned records persist longer

Attackers can set low TTLs on malicious domains to evade blacklists.

## DNSSEC Validation

DNSSEC adds cryptographic signatures to DNS records. Each zone signs its records with a private key. Resolvers verify signatures using public keys.

**Chain of trust:**
1. Root zone signs `.com` public key
2. `.com` signs `example.com` public key  
3. `example.com` signs its own records

The WHOIS command shows DNSSEC status (`whois_lookup.py:113-114`):
```python
if hasattr(w, "dnssec"):
    result.dnssec = str(w.dnssec) if w.dnssec else None
```

## Error Responses and Their Meanings

The resolver handles multiple error conditions (`resolver.py:181-189`):

**NXDOMAIN**: Domain doesn't exist
- Could indicate typosquatting attempts
- Useful for detecting malware C2 using DGA (domain generation algorithms)

**NOERROR with empty answer**: Domain exists but no record of that type
- Indicates misconfiguration or incomplete setup

**SERVFAIL**: Server encountered error processing query
- Could indicate DNSSEC validation failure
- Might suggest DNS server under attack

**Timeout**: No response received
- Network issues
- Firewall blocking
- DNS server overloaded or down

## Async Operations and Performance

DNS queries are I/O-bound. The tool uses `asyncio` for concurrency (`resolver.py:233-242`):
```python
tasks = [
    query_record_type(domain, rt, resolver) for rt in record_types
]
query_results = await asyncio.gather(*tasks, return_exceptions=True)
```

This queries all record types simultaneously instead of sequentially. For 7 record types with 50ms latency each:
- Sequential: 350ms
- Concurrent: 50ms

The batch command applies this to multiple domains (`resolver.py:428-440`).

## Common Mistakes and Misconceptions

**Mistake 1: Trusting DNS responses**
DNS has no built-in authentication. Without DNSSEC, responses could be forged.

**Mistake 2: Hardcoding IP addresses to avoid DNS**
IPs change. Cloud services use dynamic IPs. DNS provides flexibility.

**Mistake 3: Ignoring reverse DNS**
PTR records help validate server identity. Their absence is suspicious.

**Mistake 4: Not monitoring DNS queries**
DNS query logs reveal reconnaissance, data exfiltration, and C2 traffic.

**Mistake 5: Caching too aggressively**
Stale DNS data can persist long after infrastructure changes.

## Industry Standards and References

**OWASP References:**
- Testing for DNS Zone Transfer (OTG-INFO-002)
- Testing DNS Spoofing (OTG-INPVAL-007)

**MITRE ATT&CK Techniques:**
- T1071.004: DNS tunneling for command and control
- T1590.002: DNS reconnaissance
- T1584.002: Compromise DNS infrastructure

**RFCs to Study:**
- RFC 1035: DNS specification
- RFC 4033-4035: DNSSEC
- RFC 7858: DNS over TLS
- RFC 8484: DNS over HTTPS

Next, see `02-ARCHITECTURE.md` for how this tool implements these concepts in code.
