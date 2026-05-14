# Core Security Concepts

This document explains the security concepts you'll encounter while building this project. These aren't just definitions. We'll dig into why they matter and how they actually work.

## Linux Capabilities

### What It Is

Linux capabilities split the monolithic root privilege into 41 discrete permissions. Instead of checking "is this process root?", the kernel checks "does this process have CAP_NET_ADMIN?" before allowing network configuration changes.

The capability model was introduced in kernel 2.2 (1999) to enable privilege separation. A web server binding to port 80 only needs `CAP_NET_BIND_SERVICE`, not full root access. A backup program only needs `CAP_DAC_READ_SEARCH` to read protected files.

### Why It Matters

Containers run with a default set of capabilities that enable common operations. Docker drops 13 dangerous capabilities by default but still grants 14 others. Adding back dropped capabilities or granting new ones can enable complete container escape.

When you run `docker run --privileged`, Docker grants all 41 capabilities. This is equivalent to running as root on the host, bypassing every container isolation mechanism.

### How It Works

Capabilities are stored as 64-bit bitmasks in the process credential structure. The kernel checks these bits before privileged operations. Here's how this project decodes them from `/proc/PID/status`:

```go
// internal/proc/capabilities.go:87-112
func (c *CapabilitySet) HasCapability(name string) bool {
    bit, ok := capabilityNames[name]
    if !ok {
        return false
    }
    return (c.Effective & (1 << bit)) != 0
}
```

The `Effective` set determines what the process can currently do. Other sets (`Permitted`, `Inheritable`, `Bounding`, `Ambient`) control capability transitions across exec() and privilege changes.

The project maps all 41 capabilities to severity levels in `internal/rules/capabilities.go:24-323`:

```go
"CAP_SYS_ADMIN": {
    Severity:    finding.SeverityCritical,
    Description: "Perform a range of system administration operations...",
}
```

When scanning containers, the code at `internal/analyzer/container.go:76-102` iterates added capabilities and creates findings for dangerous ones:

```go
for _, cap := range info.HostConfig.CapAdd {
    capName := strings.ToUpper(string(cap))
    capInfo, exists := rules.GetCapabilityInfo(capName)
    if !exists {
        continue
    }
    if capInfo.Severity >= finding.SeverityHigh {
        // Create finding with severity from capability database
    }
}
```

### Common Attacks

**Container escape via CAP_SYS_ADMIN**

This capability enables mounting filesystems. An attacker can mount the host's root filesystem inside the container:

```bash
# Inside container with CAP_SYS_ADMIN
mkdir /host
mount /dev/sda1 /host
chroot /host
# Now running on the host
```

The Shocker exploit (CVE-2014-6407) used `CAP_DAC_READ_SEARCH` similarly. It could open any file descriptor by path, bypassing namespace isolation.

**Process injection via CAP_SYS_PTRACE**

With this capability, a process can use ptrace() to attach to any other process, read its memory, and inject code:

```c
ptrace(PTRACE_ATTACH, target_pid, NULL, NULL);
ptrace(PTRACE_POKETEXT, target_pid, address, shellcode);
ptrace(PTRACE_SETREGS, target_pid, NULL, &regs);
ptrace(PTRACE_CONT, target_pid, NULL, NULL);
```

An attacker in a container with `CAP_SYS_PTRACE` and `--pid=host` can inject into PID 1 on the host.

**Network manipulation via CAP_NET_ADMIN**

This capability allows modifying routing tables, firewall rules, and network namespaces. An attacker can:

- Redirect traffic destined for other containers
- Create network tunnels to exfiltrate data
- Modify iptables rules to bypass network policies
- Escape to the host network namespace

### Defense Strategies

Drop all capabilities, then add back only what's needed:

```bash
docker run --cap-drop=ALL --cap-add=NET_BIND_SERVICE nginx
```

This project detects when containers add dangerous capabilities. The severity comes from the capability database, not hardcoded logic. Adding a new risky capability just requires updating `internal/rules/capabilities.go`.

## Namespace Isolation

### What It Is

Linux namespaces provide separate views of system resources. Processes in different namespaces see different sets of PIDs, network interfaces, mount points, IPC objects, hostnames, users, and cgroups.

Docker creates 6 namespaces for each container by default:
- **PID namespace** - isolates process IDs
- **Network namespace** - isolates network interfaces
- **Mount namespace** - isolates filesystem mount points
- **IPC namespace** - isolates System V IPC and POSIX message queues
- **UTS namespace** - isolates hostname and domain name
- **User namespace** - isolates user and group IDs (optional, not default)

### Why It Matters

Sharing a namespace with the host breaks that isolation boundary. Running with `--pid=host` lets the container see all host processes. With `CAP_SYS_PTRACE`, it can inject into them.

The most dangerous is `--net=host`, which puts the container on the host network stack. The container can now bind to any host port, sniff all traffic, and reconfigure the host's network.

### How It Works

The kernel maintains a namespace inode for each namespace type. Processes belong to namespaces via these inodes. The `/proc/PID/ns/` directory exposes these as symlinks:

```bash
$ ls -l /proc/self/ns/
lrwxrwxrwx 1 user user 0 Jan 31 12:00 pid -> 'pid:[4026531836]'
lrwxrwxrwx 1 user user 0 Jan 31 12:00 net -> 'net:[4026531840]'
```

Containers in different namespaces have different inode numbers. The code at `internal/analyzer/container.go:125-161` checks if containers share host namespaces:

```go
if info.HostConfig.NetworkMode == "host" {
    control, _ := benchmark.Get("5.9")
    f := finding.New("CIS-5.9", control.Title, finding.SeverityHigh, target)
    findings = append(findings, f)
}
```

Kubernetes manifests make this mistake often:

```yaml
spec:
  hostNetwork: true  # Shares host network namespace
  hostPID: true      # Shares host PID namespace
  containers:
  - name: monitor
    image: debug-tools
```

### Common Attacks

**Host process discovery via --pid=host**

With the host PID namespace, an attacker can enumerate all host processes, find sensitive services, and identify attack targets:

```bash
# Inside container with --pid=host
ps aux | grep -i password
ls -la /proc/*/environ | xargs grep -a SECRET
```

This exposes process command lines, environment variables, and open file descriptors.

**Network sniffing via --net=host**

On the host network namespace, the container can run packet capture tools to intercept traffic intended for other containers or the host:

```bash
tcpdump -i eth0 -w capture.pcap
# Exfiltrate capture.pcap later
```

This bypasses Docker's network isolation completely.

### Defense Strategies

Never share host namespaces in production. The code at `internal/analyzer/container.go:145-161` flags all shared namespaces:

```go
if info.HostConfig.PidMode == "host" {
    // Creates HIGH severity finding for CIS 5.15
}
if info.HostConfig.IpcMode == "host" {
    // Creates HIGH severity finding for CIS 5.16
}
```

For debugging, use `docker exec` to run tools in the container's namespaces rather than sharing the host's.

## Security Profiles (Seccomp, AppArmor, SELinux)

### What It Is

Security profiles enforce mandatory access control beyond traditional Unix permissions:

**Seccomp** (Secure Computing Mode) filters system calls using BPF (Berkeley Packet Filter) programs. It can block dangerous syscalls like `ptrace()`, `mount()`, and `reboot()`.

**AppArmor** restricts file access using path-based rules. A profile can allow reading `/etc/nginx/` but deny writing anywhere except `/var/log/nginx/`.

**SELinux** (Security-Enhanced Linux) enforces type-based mandatory access control. It uses security contexts like `system_u:object_r:httpd_sys_content_t:s0` to control access.

### Why It Matters

Without these profiles, a compromised container has full syscall access and can attempt container escape techniques. The default Docker seccomp profile blocks about 44 dangerous syscalls, but containers can run with `--security-opt seccomp=unconfined`.

### How It Works

Docker applies a default seccomp profile unless you override it. The profile is a JSON file defining allowed syscalls:

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "architectures": ["SCMP_ARCH_X86_64"],
  "syscalls": [
    {
      "names": ["read", "write", "open"],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

The code at `internal/analyzer/container.go:163-207` checks for missing or disabled profiles:

```go
for _, opt := range info.HostConfig.SecurityOpt {
    if opt == "seccomp=unconfined" {
        // Creates HIGH severity finding
    }
}
```

AppArmor profiles are text files in `/etc/apparmor.d/`:

```
profile docker-default flags=(attach_disconnected,mediate_deleted) {
  deny @{PROC}/* w,
  deny /sys/[^f]*/** wklx,
  capability setuid,
}
```

### Common Pitfalls

**Disabling seccomp for convenience**

Developers disable seccomp when troubleshooting without understanding the risk:

```bash
# Bad: Complete syscall access
docker run --security-opt seccomp=unconfined app

# Good: Custom profile with needed syscalls
docker run --security-opt seccomp=./custom-profile.json app
```

The project detects this at `internal/analyzer/container.go:186-193`.

**Missing profiles entirely**

Older Docker versions or certain configurations don't apply profiles by default. The code checks both for explicit disabling and absence:

```go
if !hasSeccomp && !info.HostConfig.Privileged {
    // Creates MEDIUM severity finding
}
```

### Defense Strategies

Always use security profiles in production. Start with Docker's defaults and customize only when needed. The project flags both disabled and missing profiles with different severities (HIGH for explicit disabling, MEDIUM for absence).

## Sensitive Path Mounts

### What It Is

Bind mounts expose host directories and files inside containers. Some paths give full host access if mounted, like `/var/run/docker.sock` (Docker control), `/proc` (process information), and `/` (entire filesystem).

### Why It Matters

The Docker socket is a UNIX socket that accepts Docker API commands. A container with this mounted can create new privileged containers, effectively escaping to the host:

```bash
# Inside container with /var/run/docker.sock mounted
docker run --privileged -v /:/host -it ubuntu chroot /host /bin/bash
# Now on the host
```

This is how the Tesla Kubernetes breach happened.

### How It Works

Docker bind mounts are specified with `-v` or `--mount`. The Docker API includes mount information in container inspection:

```json
{
  "Mounts": [
    {
      "Type": "bind",
      "Source": "/var/run/docker.sock",
      "Destination": "/var/run/docker.sock"
    }
  ]
}
```

The code at `internal/analyzer/container.go:104-145` checks each mount against a database of 200+ dangerous paths defined in `internal/rules/paths.go`:

```go
for _, mount := range info.Mounts {
    source := mount.Source
    if rules.IsDockerSocket(source) {
        // Creates CRITICAL severity finding
    }
    if rules.IsSensitivePath(source) {
        severity := rules.GetPathSeverity(source)
        // Creates finding with path-specific severity
    }
}
```

The rules database includes:

- Container runtime sockets (Docker, containerd, CRI-O)
- System directories (`/proc`, `/sys`, `/dev`)
- Configuration directories (`/etc`, `/root`)
- Kubernetes secrets (`/var/lib/kubelet`, `/etc/kubernetes`)
- Cloud provider credentials (`/root/.aws`, `/root/.kube`)
- CI/CD agent data (`/var/lib/jenkins`, `/home/runner`)

Each path has a severity level and description in `internal/rules/paths.go:32-1100`.

### Common Attacks

**Docker socket escape**

This is the most common container escape technique:

```python
# Python script inside container
import docker
client = docker.from_env()  # Uses /var/run/docker.sock

# Create privileged container with host filesystem mounted
container = client.containers.run(
    'ubuntu',
    'chroot /host /bin/bash',
    privileged=True,
    volumes={'/': {'bind': '/host'}},
    detach=True,
    stdin_open=True,
    tty=True
)
```

**Process memory access via /proc**

Mounting `/proc` exposes host process memory. Reading `/proc/PID/mem` can extract credentials, SSH keys, and other secrets from running processes.

**Kernel manipulation via /sys**

The `/sys` filesystem exposes kernel parameters. Writing to `/sys/kernel/` can disable security features, modify CPU settings, and trigger kernel vulnerabilities.

### Defense Strategies

Never mount the Docker socket unless the container specifically provides Docker-as-a-Service (like CI/CD runners). Even then, use alternatives like Docker's rootless mode or Kaniko for builds.

The project's path database is comprehensive. Adding a new dangerous path just requires an entry in `internal/rules/paths.go`.

## Secret Detection

### What It Is

Secrets are credentials embedded in Dockerfiles, environment variables, or docker-compose files. They include API keys, passwords, private keys, database URLs, and tokens.

### Why It Matters

Secrets in container images are easily discoverable. Anyone who can pull the image can extract the secrets:

```bash
docker history image:tag
docker inspect image:tag
docker run image:tag env
```

In 2019, researchers found over 100,000 Docker Hub images with leaked secrets. Many were active API keys for AWS, GitHub, and other services.

### How It Works

This project uses two techniques for secret detection:

**Pattern matching** with 80+ regular expressions in `internal/rules/secrets.go:29-821`:

```go
{
    Type: SecretTypeAWSKey,
    Pattern: regexp.MustCompile(`(AKIA|ABIA|ACCA|ASIA)[0-9A-Z]{16}`),
    Description: "AWS Access Key ID",
}
```

**Entropy analysis** using Shannon entropy:

```go
// internal/rules/secrets.go:910-925
func CalculateEntropy(s string) float64 {
    freq := make(map[rune]float64)
    for _, c := range s {
        freq[c]++
    }
    length := float64(len(s))
    var entropy float64
    for _, count := range freq {
        p := count / length
        entropy -= p * math.Log2(p)
    }
    return entropy
}
```

Secrets typically have high entropy (>4.5 bits per character) because they're random. The code at `internal/analyzer/dockerfile.go:154-213` scans Dockerfiles:

```go
if rules.IsSensitiveEnvName(varName) {
    // Check if variable name looks sensitive
}
if rules.IsHighEntropyString(varValue, 16, 4.5) {
    // Check if value has high entropy
}
secrets := rules.DetectSecrets(line)
for _, secret := range secrets {
    // Create finding for each detected secret type
}
```

### Common Patterns

The project detects:
- AWS keys: `AKIA...`, `aws_secret_access_key=...`
- GitHub tokens: `ghp_...`, `gho_...`
- Google API keys: `AIza...`
- Private keys: `-----BEGIN PRIVATE KEY-----`
- JWTs: `eyJ...` (base64 encoded JSON)
- Database URLs: `postgres://user:pass@host/db`
- Generic patterns: `API_KEY=...`, `PASSWORD=...`

See `internal/rules/secrets.go:29-821` for the complete list.

### Defense Strategies

Use Docker secrets or environment variables at runtime:

```bash
# Bad: Secret in Dockerfile
ENV API_KEY=sk-abc123

# Good: Secret from environment
docker run -e API_KEY=sk-abc123 app

# Better: Docker secrets (Swarm)
echo "sk-abc123" | docker secret create api_key -
docker service create --secret api_key app
```

The project flags both hardcoded secrets and high-entropy strings in `ENV`, `ARG`, and `RUN` instructions.

## CIS Docker Benchmark

### What It Is

The CIS Docker Benchmark is a consensus-driven security configuration guide published by the Center for Internet Security. It provides 100+ controls across 7 sections:

1. Host Configuration
2. Docker Daemon Configuration  
3. Docker Daemon Files and Directories
4. Container Images and Build Files
5. Container Runtime
6. Docker Security Operations
7. Docker Swarm Configuration

Each control has an ID (like "5.4"), title, description, and remediation steps. Controls are marked as "scored" (required for compliance) or "not scored" (recommended).

### Why It Matters

The benchmark represents industry best practices developed by security practitioners. Following it prevents common misconfigurations that lead to breaches.

Many compliance frameworks (PCI DSS, HIPAA, SOC 2) require following CIS benchmarks or equivalent standards. This project automates checking compliance.

### How It Works

The project registers all CIS controls in `internal/benchmark/controls.go:61-end`. Each control includes metadata:

```go
Register(Control{
    ID:          "5.4",
    Section:     "Container Runtime",
    Title:       "Ensure that privileged containers are not used",
    Description: "Using --privileged gives all capabilities to the container...",
    Remediation: "Do not run containers with --privileged flag...",
    Severity:    finding.SeverityCritical,
    Scored:      true,
    Level:       1,
    References:  []string{"https://docs.docker.com/engine/reference/run/"},
})
```

Analyzers create findings that reference these controls:

```go
control, _ := benchmark.Get("5.4")
f := finding.New("CIS-5.4", control.Title, finding.SeverityCritical, target).
    WithDescription(control.Description).
    WithRemediation(control.Remediation).
    WithCISControl(control.ToCISControl())
```

The `--cis` flag filters findings by control ID. The SARIF output includes CIS control IDs as tags for integration with compliance tools.

### Testing Your Understanding

Before moving to the architecture, make sure you can answer:

1. Why is `CAP_SYS_ADMIN` worse than `CAP_NET_RAW`? What specific attack does each enable?
2. If a container shares the host PID namespace but has no special capabilities, can it still be dangerous? How?
3. Why do we need both pattern matching and entropy analysis for secret detection? Give an example secret that each would catch.

If these questions feel unclear, re-read the relevant sections. The implementation will make more sense once these fundamentals click.

## Further Reading

**Essential:**
- CIS Docker Benchmark v1.6.0 (PDF) - the complete specification this project implements
- Linux Programmer's Manual capabilities(7) - authoritative capability documentation
- Docker Security Documentation - official Docker security best practices

**Deep dives:**
- "Understanding and Hardening Linux Containers" (NCC Group whitepaper) - container internals and escape techniques
- "A Measurement Study of Docker Container Configurations on GitHub" (research paper) - data on real-world misconfigurations
- Kernel source: security/capability.c - how capability checks actually work in the kernel

**Historical context:**
- Original Docker security audit by ThoughtWorks (2014) - identified many issues this benchmark addresses
- "Dirty COW" (CVE-2016-5195) - kernel vulnerability exploitable from containers
- runc vulnerability CVE-2019-5736 - container escape via malicious image
