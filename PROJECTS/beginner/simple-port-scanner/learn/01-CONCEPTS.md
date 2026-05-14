# Core Security Concepts

This document explains the security concepts you'll encounter while building this project. These are not just definitions but practical knowledge used daily in penetration testing and network security.

## TCP Port Scanning

### What It Is

Port scanning is the process of probing a target host to determine which TCP or UDP ports are accepting connections. Each port number (0-65535) can have a service listening on it. Scanning reveals what software is running on a system without requiring authentication.

Think of it like checking every door and window on a building to see which ones are unlocked. Ports 1-1023 are "well-known" ports assigned to standard services (HTTP on 80, SSH on 22), while higher ports can run anything.

### Why It Matters

Port scanning is **reconnaissance**, the first phase of the cyber kill chain. Every penetration test, vulnerability assessment, and many real attacks start by mapping what's accessible. The 2017 Equifax breach started with reconnaissance that found an unpatched Apache Struts server on port 8080. Finding that open port was step one.

In the 2016 Mirai botnet attack that took down Dyn DNS, the malware scanned the entire internet for IoT devices with telnet (port 23) exposed. It found hundreds of thousands of vulnerable cameras and routers because port 23 should never be open on consumer devices facing the internet.

### How It Works

TCP port scanning exploits the three-way handshake mechanism:
```
Scanner          Target
   |               |
   |----SYN------->|  (attempt connection)
   |               |
   |<--SYN-ACK-----|  (port is OPEN - service listening)
   |               |
   |----RST------->|  (scanner aborts, doesn't complete handshake)
```

or
```
Scanner          Target
   |               |
   |----SYN------->|
   |               |
   |<---RST--------|  (port is CLOSED - no service, but host responded)
```

or
```
Scanner          Target
   |               |
   |----SYN------->|
   |               |
   |   (silence)   |  (port is FILTERED - firewall dropped packet)
```

Our scanner sends a SYN packet (connection request) and interprets the response. The Boost.Asio library handles the handshake details, but understanding what happens on the wire is crucial.

### Common Attacks

1. **Full reconnaissance before exploitation** - Attackers scan entire networks to build target databases. The WannaCry ransomware scanned for SMB (port 445) before launching the EternalBlue exploit. Port scanning identified vulnerable machines.

2. **Service-specific attacks** - Finding MySQL on port 3306 exposed to the internet means the attacker can try credential stuffing, SQL injection, or known CVEs specific to database servers. Each open port narrows the attack surface to specific exploit categories.

3. **Firewall and IDS fingerprinting** - The difference between closed and filtered ports reveals firewall rules. If ports 1-1000 return RST (closed) but 1001-2000 timeout (filtered), you know there's selective filtering. This information helps attackers identify blind spots.

### Defense Strategies

**Minimize exposed ports:** Only open what you actually need. Default installations often enable unnecessary services. Run `netstat -tuln` on Linux or `netsh interface ipv4 show tcpconnections` on Windows to see what's listening. Every open port is potential attack surface.

**Implement proper firewall rules:** Default-deny inbound traffic, explicitly allow only required services. Our scanner detects filtered ports through timeouts (`src/PortScanner.cpp:139-147`), so proper firewalling makes reconnaissance harder.

**Monitor for scanning activity:** Multiple connection attempts to sequential ports from one source IP is scanning. IDS systems like Snort have specific rules for port scan detection. The pattern of SYN packets without completing handshakes stands out in logs.

**Use port knocking or single packet authorization:** For SSH or other admin services, require a secret sequence of connection attempts before the port appears open. This hides critical services from casual scans.

## Port States and Their Meaning

### What It Is

Every port on a networked system exists in one of three states from a scanner's perspective: open, closed, or filtered. These states tell fundamentally different stories about the target.

### Why It Matters

The state reveals both the service configuration and the security posture:

- **Open**: Something is listening. This is your attack surface. In the 2020 SolarWinds supply chain attack, attackers used stolen credentials to access an internal code repository. They found it by scanning for open git server ports (commonly 443 or custom ports for GitLab/GitHub Enterprise).

- **Closed**: The host is alive and reachable, but nothing listens on that port. Closed ports confirm the target exists and responds, helping with network mapping even when services aren't exposed.

- **Filtered**: A firewall or packet filter sits between you and the target. This tells attackers there's security infrastructure, but also might reveal configuration weaknesses if some ports are filtered and others aren't.

### How It Works

Our scanner implements state detection in `src/PortScanner.cpp:123-165`:

**Open port detection** (`PortScanner.cpp:138-151`):
```cpp
socket->async_connect(endpoint, [](boost::system::error_code ec) {
    if (!ec) {
        // Connection succeeded = OPEN
        // Try to grab banner
    }
});
```
If `async_connect` completes without error, the TCP handshake succeeded. Something accepted our connection.

**Closed port detection** (`PortScanner.cpp:153-158`):
```cpp
else {
    // Connection failed = CLOSED
    printf("%i\t%sCLOSED%s\t%s\t%s\n", port, RED, RESET, ...);
}
```
If `async_connect` returns an error quickly (usually "connection refused"), the host sent us a RST packet. The port is closed.

**Filtered port detection** (`PortScanner.cpp:128-137`):
```cpp
timer->async_wait([](boost::system::error_code ec) {
    if (!ec && !*complete) {
        // Timer expired before connection = FILTERED
        printf("%i\t%s\t%s\t%s\n", port, "FILTERED", ...);
    }
});
```
If neither success nor error occurs within the timeout (default 2 seconds), we assume a firewall dropped our packets. The connection attempt just hangs until we give up.

### Common Pitfalls

**Mistake 1: Confusing closed with filtered**
```cpp
// Wrong - timing out doesn't mean closed
if (connection_timeout) {
    state = "CLOSED";  // No! This is FILTERED
}

// Right - closed is an active rejection
if (error_code == "connection_refused") {
    state = "CLOSED";
}
```
Closed means the host actively rejected you. Filtered means your packets disappeared into a firewall. This distinction matters for understanding the network topology.

**Mistake 2: Not handling false positives**
Some hosts have firewalls that send RST packets to look closed even when they're filtered. Advanced scanning needs multiple probe techniques (SYN, ACK, FIN scans) to distinguish these edge cases. Our simple scanner takes responses at face value.

## Banner Grabbing

### What It Is

Banner grabbing means connecting to a service and reading whatever initial message it sends. Many protocols announce themselves immediately upon connection. SSH servers say "SSH-2.0-OpenSSH_8.2p1", web servers send HTTP headers with "Server: Apache/2.4.41", and so on.

### Why It Matters

Service banners leak version information that attackers use for exploit selection. If your SSH banner says "OpenSSH_7.4", I can check CVE databases for known vulnerabilities in that exact version. The 2014 Heartbleed attack (CVE-2014-0160) affected OpenSSL 1.0.1 through 1.0.1f. Banner grabbing told attackers which servers were vulnerable.

The 2021 Microsoft Exchange Server attacks (ProxyLogon) targeted specific Exchange versions. Attackers scanned for Exchange servers, grabbed banners to identify versions, then launched targeted exploits. Version information turned a generic scan into a precision strike.

### How It Works

After successfully connecting to an open port, we try to read initial data:
```cpp
// src/PortScanner.cpp:143-149
socket->async_read_some(boost::asio::buffer(*buf),
    [](boost::system::error_code ec, std::size_t n) {
        if (!ec && n > 0) {
            banner->assign(buf->data(), n);
        }
        printf("%i\tOPEN\t%s\t%s\n", port, service.c_str(), banner->c_str());
    });
```

We allocate a 128-byte buffer and attempt a non-blocking read. If the service sends anything immediately, we capture it. If not (many services wait for client input first), we proceed without a banner. This is a passive grab - we don't send protocol-specific probes.

Some services require you to speak their protocol first. HTTP servers need you to send "GET / HTTP/1.1" before they respond. Our scanner just listens, which works for chatty services like SSH, SMTP, and FTP that announce themselves.

### Common Attacks

1. **Version-specific exploit targeting** - After finding MySQL on port 3306 and grabbing "5.5.62-0ubuntu0.14.04.1", attackers search Exploit-DB for MySQL 5.5.x vulnerabilities. Banner grabbing turns generic port finding into precise vulnerability mapping.

2. **Identifying outdated software** - Any server announcing a version from 2015 is probably vulnerable to multiple CVEs. Attackers prioritize these targets. In 2017, the Shadow Brokers leaked NSA exploits specifically tied to Windows version detection that came from SMB banners.

3. **Fingerprinting for lateral movement** - Inside a network, banner grabbing reveals the infrastructure. Finding "VMware ESXi 6.0" on port 443 tells an attacker this is a virtualization host worth compromising (one ESXi host controls many VMs).

### Defense Strategies

**Suppress version information in banners:** Most services let you customize what they announce. SSH config has `DebianBanner no`, Apache has `ServerTokens Prod`, and Nginx has `server_tokens off`. Don't advertise your exact version.

**Use generic error messages:** Don't let your application errors leak framework versions. "Error 500" is better than "Ruby on Rails 5.2.3 - NoMethodError in UsersController#create".

**Implement banner randomization or honeypots:** Advanced setups randomize banner strings or advertise fake vulnerable versions to waste attacker time. If your SSH banner claims to be from 2012 but you're fully patched, scanners will mark you as low-hanging fruit while you detect their probes.

## How These Concepts Relate

Port scanning, state detection, and banner grabbing form a reconnaissance pipeline:
```
Port Scan
    ↓
Identifies OPEN ports
    ↓
Banner Grab
    ↓
Reveals service versions
    ↓
Vulnerability Mapping
    ↓
Exploitation
```

Each step builds on the previous. You can't grab banners without finding open ports first. You can't identify vulnerabilities without knowing versions. Understanding this chain helps both attackers (who execute it) and defenders (who must break it).

## Industry Standards and Frameworks

### OWASP Top 10

This project relates to:

- **A05:2021 – Security Misconfiguration** - Unnecessary open ports are misconfigurations. Every exposed service that doesn't need to be public increases attack surface. Port scanning identifies these mistakes.

- **A01:2021 – Broken Access Control** - Services listening on public interfaces when they should be localhost-only represent broken access control. Scanning reveals these architectural flaws.

### MITRE ATT&CK

Relevant techniques:

- **T1046 - Network Service Discovery** - Port scanning is explicitly listed as a technique for discovering services. Our tool directly implements this reconnaissance method.

- **T1595.001 - Active Scanning: Scanning IP Blocks** - Automated tools scan IP ranges to find targets. This project demonstrates how such tools work at the implementation level.

### CWE

Common weakness enumerations covered:

- **CWE-200 - Exposure of Sensitive Information to an Unauthorized Actor** - Banner grabbing exploits services that reveal version info. Fixing CWE-200 means sanitizing banners.

- **CWE-1188 - Insecure Default Initialization of Resource** - Default installations often open unnecessary ports. Port scans find these unintentional exposures.

## Real World Examples

### Case Study 1: The Mirai Botnet (2016)

The Mirai IoT botnet enslaved hundreds of thousands of devices by scanning the entire internet for telnet (port 23) and SSH (port 22) with default credentials. The attack sequence was:

1. Scan random IP addresses for open ports 23/22 (network service discovery)
2. Grab telnet banners to identify device types (some IoT devices announce model numbers)
3. Try default credentials (admin/admin, root/root) based on device fingerprints
4. Install malware and join the botnet

The Dyn DNS DDoS attack that took down Twitter, Netflix, and Reddit in October 2016 came from Mirai-infected devices. This started with port scanning. The infection spread because consumer IoT devices shipped with telnet enabled and unchangeable default passwords.

**How this could have been prevented:** Manufacturers should have disabled telnet by default, required password changes on first boot, and implemented port scan detection that auto-blacklists scanners. ISPs could have filtered outbound port 23 traffic from consumer networks.

### Case Study 2: SolarWinds Supply Chain Attack (2020)

While the initial compromise happened through a trojanized software update, the attackers used port scanning during lateral movement inside victim networks. After gaining initial access, they:

1. Scanned internal networks for common management ports (3389 for RDP, 5985 for WinRM)
2. Identified Active Directory servers (ports 88, 389, 636)
3. Found backup systems and security tools to disable them
4. Mapped network architecture by correlating open ports across subnets

The attackers spent months inside networks, methodically scanning and documenting infrastructure before exfiltrating data. Port scanning was their map-making tool.

**How this could have been prevented:** Network segmentation with strict firewall rules between zones, monitoring for internal port scanning (east-west traffic analysis), and deploying deception technology (fake services on honeypot ports that alert when scanned).

## Testing Your Understanding

Before moving to the architecture, make sure you can answer:

1. **Why does our scanner use timeouts to detect filtered ports instead of just waiting for RST packets?** (Hint: what happens to packets that hit a firewall configured with DROP instead of REJECT?)

2. **If you scan a web server on port 80 and grab the banner "Server: Apache/2.4.41 (Ubuntu)", what specific pieces of information did you learn that help an attacker?** (Think about OS, software version, and potential vulnerabilities.)

3. **Explain why closed ports still provide useful reconnaissance information even though no service is running.** (What does a RST response tell you about the target?)

If these questions feel unclear, re-read the relevant sections. The implementation will make more sense once you understand what each port state means and why banner grabbing matters for real attacks.

## Further Reading

**Essential:**

- **RFC 793 - TCP Specification** - The original TCP RFC explains the three-way handshake and RST behavior. Section 3.4 covers connection establishment. Understanding this makes port scanning theory clear.

- **Nmap Network Scanning by Gordon Lyon** - The definitive book on port scanning techniques. Chapters 3-5 cover TCP scanning methods including SYN, connect, and ACK scans. Available free at nmap.org/book/.

**Deep dives:**

- **IANA Service Name and Transport Protocol Port Number Registry** - Official list of registered ports and their services. When our scanner shows "SSH" for port 22, this is where that mapping comes from: iana.org/assignments/service-names-port-numbers/.

- **Snort IDS rule documentation** - Rules 1-1999 cover scan detection. Reading these shows what patterns trigger alerts and how to evade basic IDS: snort.org/rules.

**Historical context:**

- **Phrack Issue 49 (1996) - The Art of Port Scanning** - Fyodor's original article introducing stealth scanning techniques. While dated, it explains the fundamental theory that modern tools still use.
