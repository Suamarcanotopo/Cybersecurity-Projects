<!-- © AngelaMos | 2026 | 01-CONCEPTS.md -->

# Security Concepts

This file covers the theory behind Linux firewalling and the specific problems
that `fwrule` is built to detect. Every concept here ties back to real code in
the project or to real incidents where someone got it wrong and paid for it.

---

## Netfilter Architecture

Every Linux firewall you have heard of (iptables, nftables, firewalld, ufw) is
a frontend for the same kernel framework: **netfilter**. It sits inside the
Linux networking stack and provides five hook points where the kernel can
inspect, modify, or drop packets as they move through the system.

### Packet Flow

When a packet arrives at a Linux machine, it takes one of two paths depending
on the routing table. If the destination IP belongs to this machine, the packet
goes to INPUT. If the destination is somewhere else and IP forwarding is enabled
(`net.ipv4.ip_forward = 1`), it goes to FORWARD. A packet never hits both.

```
                           NETWORK
                              |
                              v
                     +------------------+
                     |    PREROUTING    |  raw, mangle, nat (DNAT)
                     +------------------+
                              |
                       Routing Decision
                       /            \
                      v              v
              +----------+    +-----------+
              |  INPUT   |    |  FORWARD  |
              | filter,  |    | filter,   |
              | mangle,  |    | mangle,   |
              | security |    | security  |
              +----------+    +-----------+
                   |                |
                   v                v
             Local Process    +------------------+
                   |          |   POSTROUTING    |  mangle, nat (SNAT/MASQ)
                   v          +------------------+
              +----------+           |
              |  OUTPUT  |           v
              | raw,     |       NETWORK
              | mangle,  |
              | nat,     |
              | filter,  |
              | security |
              +----------+
                   |
                   v
              +------------------+
              |   POSTROUTING    |
              +------------------+
                   |
                   v
                NETWORK
```

### The Five Hooks

| Hook | When It Fires | Typical Use |
|------|--------------|-------------|
| PREROUTING | Packet just arrived, before routing decision | DNAT (port forwarding), connection tracking entry |
| INPUT | Packet destined for this machine | Filtering inbound traffic to local services |
| FORWARD | Packet passing through (this box is a router) | Filtering between network segments |
| OUTPUT | Packet originated from a local process | Filtering outbound traffic |
| POSTROUTING | Packet about to leave, after routing decision | SNAT, masquerading for NAT gateways |

### Tables

Netfilter organizes rules into five tables, each with a specific job:

| Table | Purpose | Available Chains |
|-------|---------|-----------------|
| **filter** | Accept/drop/reject decisions | INPUT, FORWARD, OUTPUT |
| **nat** | Network Address Translation | PREROUTING, OUTPUT, POSTROUTING |
| **mangle** | Packet header modification (TTL, TOS, marking) | All five |
| **raw** | Bypass connection tracking | PREROUTING, OUTPUT |
| **security** | SELinux/AppArmor labeling | INPUT, FORWARD, OUTPUT |

The `fwrule` tool models all five in its `Table` enum (`src/models/models.v`),
but the vast majority of real-world rulesets live in `filter`. That is where
accept/drop decisions happen, and where misconfigurations cause breaches.

The `raw` table deserves a note: rules here run before conntrack, so you can
mark high-volume traffic (like DNS on a busy resolver) with `NOTRACK` to skip
connection tracking entirely. This matters when the conntrack table fills up
on NAT gateways handling hundreds of thousands of concurrent connections. When
that happens, the kernel drops new connections and you see
`nf_conntrack: table full, dropping packet` in dmesg.

---

## iptables vs nftables

### iptables: The Legacy Tool

`iptables` has been the standard Linux firewall CLI since the 2.4 kernel (2001).
An `iptables-save` dump looks like this:

```
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A INPUT -p tcp --dport 22 -j ACCEPT
-A INPUT -p tcp --dport 80 -j ACCEPT
-A INPUT -p tcp --dport 443 -j ACCEPT
-A INPUT -j LOG --log-prefix "DROPPED: "
-A INPUT -j DROP
COMMIT
```

The format: `*filter` declares the table, `:INPUT DROP [0:0]` sets the chain
policy and packet/byte counters, `-A INPUT` appends a rule, `-j ACCEPT` is
the jump target, `COMMIT` atomically applies the table.

Limitations worth knowing:

- Separate binaries for IPv4 (`iptables`), IPv6 (`ip6tables`), ARP
  (`arptables`), and bridge filtering (`ebtables`)
- Rules are a flat list of conditions with match extensions (`-m conntrack`,
  `-m limit`, `-m multiport`)
- Ruleset updates replace one table at a time, not the entire ruleset atomically

### nftables: The Replacement

`nftables` replaced iptables starting with Linux 3.13 (2014). Debian 10+,
RHEL 8+, Fedora 18+, and Ubuntu 20.10+ all default to it. The same ruleset
in nftables syntax:

```
table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        iifname "lo" accept
        ct state established,related accept
        tcp dport 22 accept
        tcp dport 80 accept
        tcp dport 443 accept
        log prefix "DROPPED: " drop
    }
}
```

### Key Differences

| Feature | iptables | nftables |
|---------|----------|----------|
| IPv4/IPv6 | Separate binaries | Unified (`inet` family) |
| Syntax | Flag-based (`-p tcp --dport 22`) | Expression-based (`tcp dport 22`) |
| Atomicity | Per-table | Entire ruleset in one transaction |
| Sets | No native support | Native sets and maps (`{ 22, 80, 443 }`) |
| Multiple actions | One target per rule | Chain multiple statements |
| Performance | Linear rule matching | Sets use hash lookups (O(1) vs O(n)) |

The set syntax is a concrete improvement. This nftables line:

```
tcp dport { 22, 80, 443 } accept
```

replaces three separate iptables rules. The kernel evaluates the set with a
hash lookup instead of walking three rules sequentially.

### Why Both Still Exist

nftables ships with a compatibility layer (`iptables-nft`) that translates
iptables commands into nftables rules behind the scenes. Many distributions
install this by default, so running `iptables` actually creates nftables rules
without the user knowing. This is why you can run `iptables -L` on a modern
system and see rules, then run `nft list ruleset` and see the same rules in
nftables format.

The `fwrule export` command handles conversion between formats, which is useful
during migration.

---

## Rule Evaluation Order

### First-Match-Wins

This is the single most important concept in firewall configuration: **the
first matching rule wins**. The kernel walks through each rule in order, top
to bottom. The moment a packet matches a rule with a terminating target
(ACCEPT, DROP, REJECT), evaluation stops. The packet never sees the remaining
rules.

Two rulesets with identical rules in different order can have completely
different security properties:

```
Ordering A (secure):                     Ordering B (broken):
1. -s 10.0.0.5 -p tcp --dport 22 -j DROP    1. -p tcp --dport 22 -j ACCEPT
2. -p tcp --dport 22 -j ACCEPT              2. -s 10.0.0.5 -p tcp --dport 22 -j DROP
```

Ordering A blocks SSH from 10.0.0.5, then allows everyone else.
Ordering B allows SSH from everywhere including 10.0.0.5. Rule 2 is dead code.
Same rules, opposite security outcome.

### Chain Policies

Every built-in chain has a default policy that fires when no rule matches:

```
:INPUT DROP [0:0]     <-- default deny (fail-closed)
:INPUT ACCEPT [0:0]   <-- default accept (fail-open)
```

Default deny means anything you forgot to allow is blocked. Default accept
means anything you forgot to block gets through. The `fwrule harden` command
always generates `DROP` on INPUT and FORWARD, `ACCEPT` on OUTPUT.

### The Shadowing Problem

Shadowing is the most common firewall misconfiguration. It happens when a
broad rule early in the chain silently prevents a more specific rule later
from ever matching.

Walk through this numbered ruleset from `testdata/iptables_conflicts.rules`:

```
Rule  7: -A INPUT -p tcp --dport 22 -j ACCEPT
Rule  8: -A INPUT -s 10.0.0.0/8 -p tcp --dport 22 -j ACCEPT
Rule  9: -A INPUT -p tcp --dport 80 -j ACCEPT
Rule 10: -A INPUT -p tcp --dport 80 -j ACCEPT
Rule 11: -A INPUT -s 192.168.1.0/24 -p tcp --dport 443 -j ACCEPT
Rule 12: -A INPUT -s 192.168.0.0/16 -p tcp --dport 443 -j DROP
```

What happens:

- **Rule 8 is shadowed by Rule 7.** Rule 7 accepts SSH from any source. Rule 8
  accepts SSH only from 10.0.0.0/8. Since Rule 7 already accepted all SSH
  traffic, Rule 8 can never fire. The `find_shadowed_rules` function in
  `src/analyzer/conflict.v` catches this by checking whether Rule 7's match
  criteria is a superset of Rule 8's.

- **Rules 9 and 10 are duplicates.** Both accept TCP port 80 with no source
  restriction. Rule 10 is dead weight.

- **Rules 11 and 12 contradict.** 192.168.1.0/24 is inside 192.168.0.0/16.
  Hosts in 192.168.1.0/24 match Rule 11 (ACCEPT) first. The rest of
  192.168.0.0/16 hits Rule 12 (DROP). This might be intentional, but
  overlapping criteria with opposite actions always deserves review. The
  `find_contradictions` function flags it.

The tool performs this analysis by running pairwise comparison across every
rule in each chain. For each pair (i, j) where i < j, it calls
`match_is_superset(rules[i].criteria, rules[j].criteria)`. That function
checks protocol, source address, destination address, ports, interfaces,
and conntrack states. If every field of the earlier rule encompasses the
later rule, the later rule is shadowed.

---

## Connection Tracking (conntrack)

### Stateful vs Stateless

Without connection tracking, a firewall is stateless. It evaluates each packet
in isolation with no memory of previous packets. If you allow inbound traffic
to port 80, you also need a separate rule to allow response packets going
back out on ephemeral ports (1024-65535). That is a huge attack surface.

Connection tracking solves this. The kernel maintains a table of every active
connection (stored in `/proc/sys/net/netfilter/nf_conntrack_max`, typically
65536 entries by default, each consuming about 300-400 bytes of kernel memory).
Each tracked flow gets classified into a state.

### The Four States

| State | Meaning | Example |
|-------|---------|---------|
| **NEW** | First packet of a connection | TCP SYN, first UDP datagram |
| **ESTABLISHED** | Part of a bidirectional flow | Anything after the SYN/SYN-ACK exchange |
| **RELATED** | New connection spawned by an existing one | FTP data channel, ICMP error responses |
| **INVALID** | Cannot be associated with any known connection | Corrupted packet, out-of-window TCP sequence |

### Why ESTABLISHED,RELATED Must Be Near the Top

Look at the standard pattern from `testdata/iptables_basic.rules`:

```
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A INPUT -m conntrack --ctstate INVALID -j DROP
-A INPUT -p tcp --dport 22 -j ACCEPT
```

On a busy server, 90%+ of packets belong to established connections. If the
conntrack rule is at position 2, those packets match immediately and skip
everything else. If you bury it at position 10, every established packet
walks past 9 rules before it matches. That is thousands of unnecessary rule
evaluations per second under load.

The `find_missing_conntrack` function in `src/analyzer/optimizer.v` detects
two problems: chains with no ESTABLISHED/RELATED rule at all (warning), and
chains where the rule exists but is positioned past the third slot (info
suggestion to move it up).

### RELATED Connections

RELATED is less obvious than ESTABLISHED but equally important. Two scenarios:

**FTP data channels:** FTP uses port 21 for control and a separate connection
for data transfer. The kernel's `nf_conntrack_ftp` helper module watches the
control channel, sees the PORT or PASV command, and marks the resulting data
connection as RELATED. Without RELATED in your conntrack rule, FTP data
transfers break even though port 21 is open.

**ICMP errors:** When a packet is dropped somewhere in the network, the
dropping router sends back an ICMP "destination unreachable" or "time exceeded"
message. These ICMP packets are RELATED to the original connection. Without
RELATED, your machine never receives these error messages, which breaks path
MTU discovery and makes network debugging much harder.

---

## Default Deny vs Default Accept

This is the principle of least privilege applied to network traffic.

**Default deny** (the only sane production policy):
```
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
```

You build a whitelist. Every service that needs to be reachable gets an
explicit ACCEPT rule. Anything you forgot stays blocked. If someone adds a
new service to the machine without adding a firewall rule, the service is
unreachable. That is annoying, but safe. You notice and fix it.

**Default accept** (dangerous):
```
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
```

You build a blacklist. You try to block everything bad and hope you did not
forget anything. When someone installs MySQL on the box and it binds to
0.0.0.0:3306, it is immediately reachable from the entire internet because
you never added a rule to block it. You might not notice for months.

The difference between these two comes down to what happens when something
goes wrong. Default deny fails closed (the safe direction). Default accept
fails open (the dangerous direction). The Palo Alto Unit 42 2023 Cloud Threat
Report found 76% of organizations had publicly exposed SSH in at least one
cloud environment, almost always because of default-accept equivalent
configurations on security groups.

---

## Real-World Breaches

### Capital One (2019)

In March 2019, a former AWS employee exploited a Server-Side Request Forgery
(SSRF) vulnerability in a misconfigured WAF protecting Capital One's AWS
infrastructure. The WAF had an IAM role with excessive permissions, and the
firewall rules allowed the compromised instance to reach the EC2 metadata
service at 169.254.169.254. The attacker queried the metadata endpoint to
obtain temporary IAM credentials, used them to list and download S3 buckets,
and exfiltrated data because outbound traffic was unrestricted.

A single egress firewall rule would have stopped the exfiltration:

```
-A OUTPUT -d 169.254.169.254/32 -j DROP
```

Impact: 100 million credit applications exposed, 140,000 Social Security
numbers, 80,000 bank account numbers. Capital One paid an $80 million fine
to the OCC and $190 million in settlements. (United States v. Paige A.
Thompson, Case No. CR19-159, W.D. Wash. 2019.)

### Imperva (2019)

Imperva disclosed a security incident where an internal database instance
had a misconfigured AWS security group that allowed unauthorized access. The
exposed instance should have been network-isolated, but its security group
rules permitted inbound connections they should not have. An attacker obtained
API keys from the instance and used them to access customer data. The root
cause was a security group that was too permissive on an instance that never
needed external connectivity.

This is the exact pattern `fwrule` flags as "overly permissive": a rule
matching source 0.0.0.0/0 on a port that should be restricted to an internal
subnet.

### NSA Advisory on IPsec VPN Firewalls (U/OO/179891-20)

The National Security Agency published guidance specifically about
misconfigured firewall rules around VPN infrastructure. The advisory
documented how adversaries exploit overly permissive rules on VPN gateways
to gain initial access to a network, then use the same misconfigured
segmentation to move laterally between network zones that should be isolated.
The specific concern: firewall rules that allow VPN traffic to reach internal
subnets without restricting which internal services are accessible, turning
the VPN into a free pass past the perimeter.

### Equifax (2017, CVE-2017-5638)

The root cause was an unpatched Apache Struts vulnerability, but the breach
was dramatically worsened by firewall and network failures. An expired SSL
certificate on a network monitoring device meant encrypted traffic inspection
stopped working for 19 months without anyone noticing. Misconfigured network
segmentation allowed the attacker to move laterally across systems for 76 days
after initial compromise, accessing 48 databases containing records of 147
million people. The combination of no patching, no monitoring, and no
segmentation turned a single web application vulnerability into one of the
largest data breaches in history. The eventual cost exceeded $1.4 billion.

### Docker/Kubernetes Default Networking

This is not a single breach but a widespread class of misconfiguration.
Docker's default bridge network inserts iptables rules directly into the
FORWARD chain and the nat table's PREROUTING chain. These rules bypass
host-level firewalls like UFW and firewalld, because Docker's rules are
evaluated before the host firewall's rules in the chain.

What this means in practice: you set up UFW on a Docker host and add rules
to block port 3306. Docker publishes a MySQL container on port 3306. UFW
reports the port as blocked. The port is actually open to the internet because
Docker's iptables rules in the FORWARD chain accept the traffic before it ever
reaches UFW's rules.

```
Packet arrives
     |
     v
PREROUTING (Docker DNAT rule matches, rewrites destination)
     |
     v
FORWARD chain
     |
     +-> Docker's ACCEPT rule fires here  <-- UFW never sees this packet
     |
     +-> UFW's rules (never reached)
```

Kubernetes has the same problem at scale. kube-proxy generates iptables or
nftables rules for every Service object. On a cluster with hundreds of
services, there can be thousands of generated rules that no human wrote or
reviewed. These rules interact with the host firewall in ways that are not
obvious from looking at either the Kubernetes configuration or the host
firewall configuration alone.

---

## Common Firewall Mistakes

These are the specific patterns `fwrule analyze` and `fwrule optimize` detect.
Each one maps to a function in `src/analyzer/conflict.v` or
`src/analyzer/optimizer.v`:

- **Shadowed rules** (`find_shadowed_rules`): A broad ACCEPT before a specific
  DENY makes the DENY unreachable. Severity: CRITICAL.

- **Missing conntrack** (`find_missing_conntrack`): No ESTABLISHED/RELATED rule
  means every packet walks the full chain. On a busy server, this is measurable
  in CPU. Severity: WARNING.

- **No rate limiting on SSH** (`find_missing_rate_limits`): Port 22 open with a
  plain ACCEPT. An attacker runs hydra with thousands of password attempts per
  minute. A limit of 3/minute with burst 5 makes brute force impractical.
  Severity: WARNING.

- **Duplicate rules** (`find_duplicates`): Two rules with identical match
  criteria and the same action. The second one is dead weight that makes
  auditing harder. Severity: WARNING.

- **Contradictory rules** (`find_contradictions`): Overlapping match criteria
  with opposite actions (ACCEPT vs DROP). Might be intentional, but needs
  human review. Severity: WARNING.

- **Default accept policy**: The chain's policy is ACCEPT, so anything not
  explicitly blocked gets through. This is the single most common
  misconfiguration on internet-facing servers.

- **Redundant rules** (`find_redundant_rules`): A narrow rule with the same
  action as a broader rule that already covers it. Not a security risk, but
  clutter that obscures the actual policy. Severity: INFO.

- **Missing logging** (`find_missing_logging`): A chain with a DROP policy but
  no LOG rule. Dropped traffic generates no audit trail, which makes incident
  response and forensics significantly harder. Severity: INFO.
