# Hands On Challenges

These challenges are based on the actual codebase. Each one extends docksec with real security checks that matter in production environments.

Start with Level 1 if you're new to the codebase. Work through them sequentially because later challenges build on earlier concepts.

## Level 1: Add Simple Checks

These challenges teach you the analyzer pattern without requiring deep Docker or security knowledge.

### Challenge 1.1: Detect :latest Image Tags

**What to build:**
Add a check that flags containers running images with the `:latest` tag or no tag at all.

**Why it matters:**
`docker run nginx` pulls nginx:latest. Tomorrow's nginx:latest might be completely different. Version pinning prevents surprise breakage and security regressions.

Real incident: In 2019, Docker Hub compromise meant `:latest` tags pointed to backdoored images for several hours. Pinned versions were unaffected.

**Where to start:**
File: `internal/analyzer/container.go`

Look at `checkPrivileged()` method (lines 72-86). Your check follows the same pattern:
```go
func (a *ContainerAnalyzer) checkImageTag(
    target finding.Target,
    info types.ContainerJSON,
) finding.Collection {
    // Your code here
    // Hint: info.Config.Image contains the full image reference
    // Examples: "nginx:latest", "postgres:13.4", "redis" (no tag)
}
```

**Implementation steps:**

1. Check if image string ends with `:latest`
2. Check if image has no `:` character (defaults to :latest)
3. Create finding using benchmark.Get("5.27") for CIS control
4. Add call to this method in `analyzeContainer()` around line 60
5. Test: `docker run -d --name test nginx:latest && docksec scan`

**Expected output:**
```
[MEDIUM] Container uses :latest tag
  Container: test
  CIS Control: 5.27
  Description: Using :latest makes image version unpredictable...
```

**Hints:**
- Use `strings.HasSuffix()` and `strings.Contains()`
- Empty tag defaults to `:latest`, so `nginx` and `nginx:latest` are equivalent
- Don't flag `nginx@sha256:abc123...` (digest pinning is good)

**Going deeper:**
After basic implementation works, handle edge cases:
- Multi-arch manifests: `nginx:latest@sha256:...` has latest tag but digest pinned
- Private registries: `registry.example.com:5000/nginx:latest`
- Official images: `nginx` vs `library/nginx` vs `docker.io/library/nginx`

### Challenge 1.2: Check for Exposed Sensitive Ports

**What to build:**
Flag containers with published ports in sensitive ranges (like 22, 3389, 5432).

**Why it matters:**
Accidentally exposing SSH (22) or RDP (3389) to 0.0.0.0 is common. Automated scanners find these in minutes.

Real example: In 2020, 45,000+ Docker hosts exposed port 2375 (Docker API) to the internet. Attackers used them for cryptomining.

**Where to start:**
File: `internal/analyzer/container.go`

Container port bindings are in `info.NetworkSettings.Ports`. This is a map where keys are container ports and values are host bindings.
```go
func (a *ContainerAnalyzer) checkExposedPorts(
    target finding.Target,
    info types.ContainerJSON,
) finding.Collection {
    // Your code here
    // Hint: info.NetworkSettings.Ports is map[nat.Port][]nat.PortBinding
}
```

**Sensitive ports to check:**
- 22 (SSH)
- 23 (Telnet)
- 3306 (MySQL)
- 5432 (PostgreSQL)
- 6379 (Redis)
- 27017 (MongoDB)
- 3389 (RDP)
- 5900 (VNC)

**Implementation steps:**

1. Create `internal/rules/ports.go` with sensitive ports map:
```go
   var SensitivePorts = map[int]string{
       22: "SSH",
       23: "Telnet",
       // ... rest
   }
```

2. Iterate over `info.NetworkSettings.Ports`
3. Parse port number from nat.Port (format: "8080/tcp")
4. Check if HostIP is "0.0.0.0" or empty (empty means all interfaces)
5. Create finding if port is sensitive and exposed to all interfaces

**Expected output:**
```
[HIGH] Sensitive port exposed to all interfaces
  Container: database
  Port: 5432 (PostgreSQL) -> 0.0.0.0:5432
  Remediation: Bind to localhost only: docker run -p 127.0.0.1:5432:5432
```

**Hints:**
- `nat.Port` format is "3306/tcp" or "53/udp"
- Use `strconv.Atoi()` to parse port number
- HostIP "0.0.0.0" means all interfaces, empty string also means all interfaces
- Binding to 127.0.0.1 limits access to local machine only

**Going deeper:**
- Check for port ranges: `-p 8000-9000:8000-9000` exposes 1000 ports
- Detect IPv6 exposures: `::` is IPv6 equivalent of `0.0.0.0`
- Kubernetes consideration: ClusterIP services don't show in container ports

### Challenge 1.3: Find Containers Without Resource Limits

**What to build:**
Check if containers have memory and CPU limits set.

**Why it matters:**
Container without memory limit can consume all host RAM. One runaway Node.js process can kill every container on the host.

Real incident: Kubernetes cluster at Shopify took down production because one pod without memory limits leaked 64GB, triggered OOM killer that killed critical system pods.

**Where to start:**
Resource limits are in `info.HostConfig.Memory` and `info.HostConfig.NanoCpus`.
```go
func (a *ContainerAnalyzer) checkResourceLimits(
    target finding.Target,
    info types.ContainerJSON,
) finding.Collection {
    var findings finding.Collection
    
    // Memory limit
    if info.HostConfig.Memory == 0 {
        // Create finding
    }
    
    // CPU limit
    if info.HostConfig.NanoCpus == 0 {
        // Create finding
    }
    
    return findings
}
```

**Implementation steps:**

1. Check `Memory` field (in bytes, 0 means unlimited)
2. Check `NanoCpus` field (1 CPU = 1e9 nanocpus, 0 means unlimited)
3. Create separate findings for each missing limit
4. Use CIS control 5.10 for memory, 5.11 for CPU

**Expected output:**
```
[MEDIUM] Container has no memory limit
  Container: web-app
  CIS Control: 5.10
  Current: unlimited
  Remediation: docker run --memory=512m ...

[MEDIUM] Container has no CPU limit
  Container: web-app
  CIS Control: 5.11
  Current: unlimited
  Remediation: docker run --cpus=1.5 ...
```

**Hints:**
- `Memory` is in bytes: 512MB = 536870912
- `NanoCpus` uses scientific notation: 2 CPUs = 2000000000
- Some platforms set minimum limits automatically (check MemoryReservation too)
- CPU shares vs CPU quota: different controls, both matter

**Going deeper:**
- Check MemorySwap (should be same as Memory or containers can swap to disk)
- Check CPUShares (relative weights between containers)
- Validate limits are reasonable (1MB memory limit will crash immediately)

## Level 2: Build New Analyzers

These challenges require understanding Docker APIs and file parsing.

### Challenge 2.1: Add Network Security Analyzer

**What to build:**
New analyzer that checks Docker network configurations for security issues.

**Security issues to detect:**
- Default bridge network usage (containers can talk to each other)
- Networks without encryption
- Networks with IPv6 enabled (often forgotten and unmonitored)
- Custom networks without proper IPAM configuration

**Why it matters:**
Docker's default bridge network has no isolation between containers. Compromised container can pivot to others on same network.

Real attack: 2018 Tesla Kubernetes cryptojacking used container networking to spread between pods, eventually compromising admin credentials.

**Where to start:**
Create `internal/analyzer/network.go`.

The pattern:
```go
type NetworkAnalyzer struct {
    client *docker.Client
}

func NewNetworkAnalyzer(client *docker.Client) *NetworkAnalyzer {
    return &NetworkAnalyzer{client: client}
}

func (a *NetworkAnalyzer) Name() string {
    return "network"
}

func (a *NetworkAnalyzer) Analyze(ctx context.Context) (finding.Collection, error) {
    networks, err := a.client.ListNetworks(ctx)
    if err != nil {
        return nil, err
    }
    
    var findings finding.Collection
    for _, network := range networks {
        findings = append(findings, a.checkNetwork(network)...)
    }
    
    return findings, nil
}
```

**Docker SDK calls you'll need:**
```go
// List all networks
client.NetworkList(ctx, types.NetworkListOptions{})

// Inspect specific network
client.NetworkInspect(ctx, networkID, types.NetworkInspectOptions{})
```

**Checks to implement:**

1. **Default bridge detection:**
   - Network name is "bridge" and Driver is "bridge"
   - Finding: Recommend user-defined networks with `--network` flag

2. **Encryption check:**
   - User-defined overlay networks (Driver == "overlay")
   - Check Options["encrypted"] != "true"
   - Finding: Enable encryption with `docker network create --opt encrypted`

3. **IPv6 enabled:**
   - Check EnableIPv6 == true
   - Finding: IPv6 often bypasses firewalls, ensure proper rules

**Implementation steps:**

1. Create analyzer file following pattern above
2. Add to `buildAnalyzers()` in scanner.go when target is "networks"
3. Add network target to CLI flags
4. Add CIS controls for network security (2.1 section)
5. Test with: `docker network ls && docksec scan --target networks`

**Expected output:**
```
[MEDIUM] Containers using default bridge network
  Network: bridge
  Containers: web-1, web-2, db-1
  CIS Control: 2.1
  Remediation: Create user-defined network: docker network create --driver bridge app-network
```

**Hints:**
- Network inspect shows which containers are connected
- Some networks are system managed (ingress, docker_gwbridge) - filter these
- Network driver determines features (bridge vs overlay vs macvlan)

**Going deeper:**
- Check for network overlap with host subnets (routing conflicts)
- Validate IPAM configuration prevents IP exhaustion
- Detect networks exposed via published ports without firewall rules

### Challenge 2.2: Add Volume Security Analyzer

**What to build:**
Analyzer checking Docker volumes for sensitive data exposure and improper permissions.

**Security checks:**
- Anonymous volumes (not managed, persist after container removal)
- Volumes containing secrets or credentials
- Volumes with world-readable permissions
- Volumes mounted in multiple containers (unintended sharing)

**Why it matters:**
Docker volumes persist data outside container filesystem. Deleted container leaves volume behind with potentially sensitive data.

Real problem: AWS found 2000+ publicly accessible Docker volumes containing database credentials and API keys from abandoned containers.

**Where to start:**
Create `internal/analyzer/volume.go`.
```go
func (a *VolumeAnalyzer) Analyze(ctx context.Context) (finding.Collection, error) {
    volumes, err := a.client.VolumeList(ctx, filters.Args{})
    if err != nil {
        return nil, err
    }
    
    var findings finding.Collection
    for _, vol := range volumes.Volumes {
        // Inspect volume
        // Check mountpoint permissions
        // Scan for secrets in volume data
        // Check usage (anonymous vs named)
    }
    
    return findings, nil
}
```

**Docker SDK calls:**
```go
// List volumes
client.VolumeList(ctx, filters.Args{})

// Inspect volume (get mountpoint path)
client.VolumeInspect(ctx, volumeID)

// Find containers using volume
client.ContainerList(ctx, types.ContainerListOptions{
    Filters: filters.NewArgs(filters.Arg("volume", volumeName)),
})
```

**Checks to implement:**

1. **Anonymous volumes:**
   - Name is hex string (64 chars)
   - No labels
   - Not referenced in any compose file

2. **Permission checks:**
   - Read volume mountpoint: `/var/lib/docker/volumes/<name>/_data`
   - Check directory mode with `os.Stat()`
   - Flag if world-readable (mode & 0004)

3. **Secret scanning:**
   - Recursively scan volume files
   - Use existing `rules.DetectSecrets()` on file contents
   - Limit scan to text files under 1MB

4. **Shared volumes:**
   - Check if multiple containers mount same volume
   - Flag as potential unintended data sharing

**Implementation steps:**

1. Create analyzer with volume listing
2. Implement permission checking using os.Stat
3. Add recursive file scanner for secrets (careful: volumes can be huge)
4. Add container cross-reference to find shared volumes
5. Handle permission errors gracefully (volumes may not be readable)

**Expected output:**
```
[HIGH] Volume contains potential secrets
  Volume: postgres_data
  File: /var/lib/docker/volumes/postgres_data/_data/pg_hba.conf
  Secret Type: Password
  Remediation: Use Docker secrets instead of files in volumes

[MEDIUM] Anonymous volume detected
  Volume: a4f32bc8d3e9f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6
  Containers: none (orphaned)
  Remediation: Remove with docker volume rm or use named volumes
```

**Hints:**
- Volume mountpoint requires root access on host, handle permission denied
- Don't scan binary files (check file extension and magic bytes)
- Anonymous volume names are SHA256 hashes (64 hex chars)
- Some volumes are managed by plugins (check Driver field)

**Going deeper:**
- Integrate with cloud provider APIs to check volume encryption at rest
- Check volume drivers for security (local vs cloud storage plugins)
- Detect volumes mounted from untrusted sources (NFS, CIFS)

### Challenge 2.3: Runtime Behavior Analyzer

**What to build:**
Analyzer that monitors container runtime behavior and detects anomalies.

**What to detect:**
- Processes running as root inside container
- Processes with unexpected capabilities (from /proc/<pid>/status)
- Network connections to suspicious IPs/ports
- File writes to sensitive paths

**Why it matters:**
Static analysis catches build-time issues. Runtime analysis catches active exploitation.

Real use case: Kubernetes runtime security tools like Falco detect crypto miners by watching for processes with names like "xmrig" or CPU usage spikes.

**Where to start:**
This is advanced. You'll need to:
1. List container processes using `/proc` filesystem
2. Read process capabilities from `/proc/<pid>/status`
3. Monitor network connections from `/proc/net/tcp`
4. Track file operations (requires inotify or BPF)

**Implementation:**
```go
func (a *RuntimeAnalyzer) Analyze(ctx context.Context) (finding.Collection, error) {
    containers, _ := a.client.ListContainers(ctx, true)
    
    var findings finding.Collection
    for _, c := range containers {
        // Get container PID namespace
        inspect, _ := a.client.InspectContainer(ctx, c.ID)
        pid := inspect.State.Pid
        
        // Read /proc/<pid>/status for capabilities
        // Read /proc/<pid>/net/tcp for network connections
        // Check process user (UID 0 = root)
    }
    
    return findings, nil
}
```

**Challenges within the challenge:**

1. **Process enumeration:**
   - Container processes are in host's PID namespace
   - Find container's root PID from inspect
   - Walk `/proc/<pid>/task/` for threads

2. **Capability parsing:**
   - `/proc/<pid>/status` has CapEff line (hex bitmask)
   - Convert hex to capability names using existing rules.Capabilities map
   - Flag unexpected capabilities (SYS_ADMIN in web server?)

3. **Network monitoring:**
   - `/proc/<pid>/net/tcp` shows open connections
   - Parse hex IP addresses and ports
   - Flag connections to known bad IPs or unusual ports

**Hints:**
- You'll need to exec into container or read host's /proc
- Container PID in inspect is host PID, not container's PID 1
- Capability mask is 64-bit hex, parse with strconv.ParseUint
- Network monitoring creates race conditions (connections are transient)

**Going deeper:**
- Use BPF/eBPF for low-overhead syscall monitoring
- Integrate with threat intel feeds for IP reputation
- Detect container escape attempts (suspicious syscalls)
- Monitor file descriptor leaks and resource exhaustion

## Level 3: Advanced Features

These challenges add significant functionality and require architectural changes.

### Challenge 3.1: Add Remediation Scripts

**What to build:**
Auto-generate shell scripts that fix detected issues.

**Example:**
Finding: "Container running with --privileged"
Generated script:
```bash
#!/bin/bash
# Fix for container 'web-1': Remove privileged flag

# Stop container
docker stop web-1

# Get current run command
docker inspect web-1 --format='{{.Config.Cmd}}'

# Recreate without --privileged
docker run -d \
  --name web-1 \
  --network bridge \
  --volume /app:/app \
  nginx:1.21.3

docker rm web-1  # Remove old container
```

**Why it matters:**
Showing the problem is good. Showing how to fix it is better. Auto-generated scripts reduce time from finding to remediation.

**Where to start:**
Add `GenerateRemediation()` method to each finding type.

File: `internal/finding/finding.go`
```go
type Finding struct {
    // ... existing fields
    RemediationScript string  // Add this field
}

func (f *Finding) GenerateScript() string {
    switch f.RuleID {
    case "CIS-5.4":  // Privileged container
        return generatePrivilegedFix(f.Target)
    case "CIS-5.3":  // Dangerous capability
        return generateCapabilityFix(f.Target, extractCapability(f.Title))
    // ... other cases
    }
    return ""
}
```

**Implementation:**

1. Extract container config from Docker inspect
2. Build new docker run command without the security issue
3. Include steps to backup/restore data if needed
4. Add validation checks before executing

**For privileged containers:**
```go
func generatePrivilegedFix(target finding.Target) string {
    // Get current container config
    // Remove --privileged flag
    // Regenerate docker run command
    // Include capability adds if needed
}
```

**For capability issues:**
```go
func generateCapabilityFix(target finding.Target, cap string) string {
    // Get current caps
    // Remove dangerous cap
    // Suggest alternatives (SYS_ADMIN -> specific caps)
}
```

**Output format:**
```bash
# Generated by docksec
# WARNING: Review before executing

# Backup container volumes
docker run --rm --volumes-from web-1 -v $(pwd):/backup alpine tar czf /backup/web-1-volumes.tar.gz /data

# Stop and remove old container
docker stop web-1
docker rm web-1

# Recreate with security fixes
docker run -d \
  --name web-1 \
  --memory=512m \
  --cpu-shares=1024 \
  --cap-drop=ALL \
  --cap-add=NET_BIND_SERVICE \
  --network=app-network \
  -v /app/data:/data \
  nginx:1.21.3

echo "Container recreated. Verify functionality before deleting backup."
```

**Hints:**
- Get original command using container inspect (Config.Cmd, HostConfig)
- Preserve environment variables and labels
- Handle volume mounts carefully (data loss risk)
- Test generated scripts in non-production first

**Going deeper:**
- Support docker-compose regeneration for compose-managed containers
- Add rollback scripts (revert to original config)
- Validate scripts with shellcheck before output
- Support Kubernetes YAML patching for K8s deployments

### Challenge 3.2: Policy-as-Code Engine

**What to build:**
Let users define custom security policies in YAML, then enforce them.

**Policy example:**
```yaml
# security-policy.yaml
policies:
  - id: company-baseline
    name: "Company Security Baseline"
    rules:
      - check: no-privileged
        severity: critical
        
      - check: require-user
        severity: high
        exclude:
          - images: ["mysql:*", "postgres:*"]  # DB containers need root
        
      - check: memory-limit
        severity: medium
        parameters:
          minimum: 128Mi
          maximum: 2Gi
          
      - check: allowed-registries
        severity: high
        parameters:
          registries:
            - "registry.company.com"
            - "gcr.io/company-*"
```

**Why it matters:**
Different environments have different requirements. Dev tolerates :latest tags, prod doesn't. Policies encode these rules as code.

Real usage: Netflix Titus enforces policies via admission controllers. Rejected 40% of initial container requests due to policy violations.

**Where to start:**
Create `internal/policy/` package.
```go
// internal/policy/policy.go
type Policy struct {
    ID    string
    Name  string
    Rules []Rule
}

type Rule struct {
    Check      string
    Severity   finding.Severity
    Parameters map[string]interface{}
    Exclude    *ExcludeConfig
}

type ExcludeConfig struct {
    Images     []string
    Containers []string
    Namespaces []string
}

func LoadPolicy(path string) (*Policy, error) {
    // Parse YAML file
}

func (p *Policy) Evaluate(findings finding.Collection) (finding.Collection, error) {
    // Filter findings based on policy rules
    // Apply exclusions
    // Override severities
}
```

**Implementation steps:**

1. Define policy schema in Go structs
2. Use gopkg.in/yaml.v3 for parsing
3. Add policy evaluation layer between scanner and reporter
4. Support pattern matching for image names (glob patterns)
5. Add policy validation (catch invalid check names)

**Policy evaluation logic:**
```go
func (r *Rule) Matches(f *finding.Finding) bool {
    // Check if finding matches rule check type
    if !r.matchesCheck(f.RuleID) {
        return false
    }
    
    // Apply exclusions
    if r.Exclude != nil && r.Exclude.Matches(f.Target) {
        return false
    }
    
    // Check parameters (memory limits, etc.)
    return r.matchesParameters(f)
}
```

**Exclusion matching:**
```go
func (e *ExcludeConfig) Matches(target finding.Target) bool {
    for _, pattern := range e.Images {
        if matched, _ := filepath.Match(pattern, target.Name); matched {
            return true
        }
    }
    return false
}
```

**Integrate with scanner:**
```go
// internal/scanner/scanner.go
func (s *Scanner) Scan(ctx context.Context) error {
    findings, _ := s.runAnalyzers(ctx, analyzers)
    
    // Apply policy if configured
    if s.cfg.PolicyFile != "" {
        policy, _ := policy.LoadPolicy(s.cfg.PolicyFile)
        findings, _ = policy.Evaluate(findings)
    }
    
    filtered := s.filterFindings(findings)
    s.reporter.Report(filtered)
}
```

**Expected output:**
```
Loading policy: security-policy.yaml
Policy: Company Security Baseline (company-baseline)
Evaluating 147 findings against 5 rules...

Excluded 12 findings:
  - mysql:8.0 (database images allowed to run as root)
  - postgres:13 (database images allowed to run as root)

Severity overrides applied: 3
  - CIS-5.27: LOW → MEDIUM (company policy)

Final results: 132 findings
  CRITICAL: 5
  HIGH: 23
  MEDIUM: 67
  LOW: 37
```

**Hints:**
- Use yaml.v3 for parsing (better error messages than v2)
- Validate policy on load (unknown check names should error)
- Support multiple policies (layered: baseline + environment-specific)
- Cache policy evaluation results (same finding checked multiple times)

**Going deeper:**
- Support policy inheritance (extend base policy)
- Add policy testing framework (test-policy.yaml)
- Implement policy versioning and migration
- Create policy library with common patterns (PCI-DSS, SOC2, etc.)

### Challenge 3.3: Continuous Monitoring Mode

**What to build:**
Long-running daemon that monitors Docker events and scans in real time.

**Features:**
- Watch Docker event stream for container start/stop
- Auto-scan new containers within seconds of creation
- Send alerts on security violations (webhook, Slack, PagerDuty)
- Maintain state of known-good containers vs flagged ones

**Why it matters:**
Scheduled scans run hourly. Real-time monitoring catches issues in seconds.

Real scenario: Developer runs `docker run --privileged` to debug. Without monitoring, you discover it in next scan (1 hour). With monitoring, alert fires in 5 seconds.

**Architecture:**
```
Docker Event Stream
        ↓
Event Processor → Analyzer Queue → Scanner
        ↓
   Finding Store → Alert Router
        ↓
   Webhooks/Slack/etc
```

**Where to start:**
Create `cmd/docksec/daemon.go` for daemon command.
```go
func newDaemonCmd(cfg *config.Config) *cobra.Command {
    cmd := &cobra.Command{
        Use:   "daemon",
        Short: "Run continuous monitoring daemon",
        RunE: func(cmd *cobra.Command, args []string) error {
            return runDaemon(cmd.Context(), cfg)
        },
    }
    
    flags := cmd.Flags()
    flags.StringVar(&cfg.WebhookURL, "webhook", "", "Webhook URL for alerts")
    flags.DurationVar(&cfg.ScanInterval, "interval", 10*time.Second, "Scan interval")
    
    return cmd
}
```

**Event processing:**
```go
// internal/daemon/daemon.go
func (d *Daemon) watchEvents(ctx context.Context) error {
    events, errs := d.client.Events(ctx, types.EventsOptions{
        Filters: filters.NewArgs(
            filters.Arg("type", "container"),
            filters.Arg("event", "start"),
            filters.Arg("event", "stop"),
        ),
    })
    
    for {
        select {
        case event := <-events:
            d.handleEvent(event)
        case err := <-errs:
            return err
        case <-ctx.Done():
            return ctx.Err()
        }
    }
}

func (d *Daemon) handleEvent(event events.Message) {
    switch event.Action {
    case "start":
        // Queue container for scanning
        d.scanQueue <- event.Actor.ID
    case "stop":
        // Remove from active tracking
        d.tracker.Remove(event.Actor.ID)
    }
}
```

**Scanning queue:**
```go
func (d *Daemon) processScanQueue(ctx context.Context) {
    for {
        select {
        case containerID := <-d.scanQueue:
            // Scan single container
            findings := d.scanContainer(ctx, containerID)
            
            // Compare with baseline
            if d.hasNewFindings(containerID, findings) {
                d.sendAlert(containerID, findings)
            }
            
            // Update baseline
            d.baseline[containerID] = findings
            
        case <-ctx.Done():
            return
        }
    }
}
```

**Alert sending:**
```go
func (d *Daemon) sendAlert(containerID string, findings finding.Collection) {
    critical := findings.FilterBySeverity(finding.SeverityCritical)
    if len(critical) == 0 {
        return
    }
    
    payload := map[string]interface{}{
        "container": containerID,
        "findings":  critical,
        "timestamp": time.Now(),
    }
    
    // Send to webhook
    d.webhook.Send(payload)
    
    // Send to Slack
    d.slack.Send(formatSlackMessage(payload))
}
```

**State management:**
```go
// Track baseline findings per container
type FindingBaseline struct {
    mu        sync.RWMutex
    baselines map[string]finding.Collection  // containerID -> findings
}

func (fb *FindingBaseline) Update(containerID string, findings finding.Collection) {
    fb.mu.Lock()
    defer fb.mu.Unlock()
    fb.baselines[containerID] = findings
}

func (fb *FindingBaseline) HasChanged(containerID string, findings finding.Collection) bool {
    fb.mu.RLock()
    defer fb.mu.RUnlock()
    
    baseline, exists := fb.baselines[containerID]
    if !exists {
        return true  // New container
    }
    
    return !finding.Equal(baseline, findings)
}
```

**Implementation steps:**

1. Create daemon command in cmd/docksec/daemon.go
2. Implement event stream watching
3. Add scan queue with rate limiting
4. Build finding comparison logic
5. Implement webhook alerts
6. Add graceful shutdown handling

**Expected output:**
```bash
$ docksec daemon --webhook=https://hooks.slack.com/... --interval=10s

Starting docksec daemon...
Watching Docker events...
Baseline: 127 containers scanned

[2025-01-31 10:23:45] Container started: web-prod-3
[2025-01-31 10:23:50] Scan complete: 3 findings (1 CRITICAL)
[2025-01-31 10:23:50] ⚠️  Alert sent: Privileged container detected

[2025-01-31 10:25:12] Container stopped: worker-7
[2025-01-31 10:25:12] Removed from tracking
```

**Slack alert format:**
```
🚨 Critical Security Finding

Container: web-prod-3
Image: nginx:latest
Finding: Container running with --privileged flag
Severity: CRITICAL
CIS Control: 5.4

Started: 2025-01-31 10:23:45
Scanned: 2025-01-31 10:23:50

Remediation: Recreate container without --privileged flag
```

**Hints:**
- Docker Events API can miss events if processing is slow (use buffered channel)
- Rate limit scans to avoid overloading daemon
- Persist baseline to disk (survive daemon restarts)
- Handle container rename events (ID stays same, name changes)

**Going deeper:**
- Add Prometheus metrics exporter (/metrics endpoint)
- Implement alert deduplication (don't spam same alert)
- Support alert routing rules (critical → PagerDuty, low → email)
- Add web UI showing real-time container status
- Integrate with SIEM systems (Splunk, Elasticsearch)

## Level 4: Production Readiness

These challenges make docksec production-grade.

### Challenge 4.1: Performance Optimization

**What to build:**
Make scanner handle 10,000+ containers without timing out or consuming excessive memory.

**Current bottlenecks:**

1. **Sequential CIS control lookups:**
   `benchmark.Get("5.4")` called for every finding
   
2. **String operations in hot path:**
   `strings.ToUpper()` on every capability check
   
3. **Unbounded memory growth:**
   All findings held in memory until end

**Optimization 1: Pre-compute control lookups**

Before:
```go
func (a *ContainerAnalyzer) checkPrivileged(...) finding.Collection {
    control, _ := benchmark.Get("5.4")  // Map lookup every call
    f := finding.New("CIS-5.4", control.Title, ...)
}
```

After:
```go
var (
    controlPrivileged = benchmark.MustGet("5.4")  // Lookup once at init
    controlCapabilities = benchmark.MustGet("5.3")
    controlMounts = benchmark.MustGet("5.5")
)

func (a *ContainerAnalyzer) checkPrivileged(...) finding.Collection {
    f := finding.New("CIS-5.4", controlPrivileged.Title, ...)
}
```

**Optimization 2: Capability map keygen**

Before:
```go
cap = strings.ToUpper(string(cap))  // Allocates new string
capInfo, exists := rules.GetCapabilityInfo(cap)
```

After:
```go
// Build lookup with both cases at init
var capabilityLookup = buildCapabilityLookup()

func buildCapabilityLookup() map[string]CapabilityInfo {
    m := make(map[string]CapabilityInfo, len(Capabilities)*2)
    for cap, info := range Capabilities {
        m[cap] = info
        m[strings.ToLower(cap)] = info  // Support lowercase
        m[strings.TrimPrefix(cap, "CAP_")] = info  // Without prefix
    }
    return m
}

// Now direct lookup without string operations
capInfo, exists := capabilityLookup[string(cap)]
```

**Optimization 3: Streaming output**

Before:
```go
// Collect all findings
findings = append(findings, ...)

// Write at end
reporter.Report(findings)
```

After:
```go
// Stream findings as discovered
findingsChan := make(chan finding.Finding, 100)

go func() {
    for f := range findingsChan {
        reporter.ReportOne(f)  // Write immediately
    }
}()

// Analyzer sends to channel
findingsChan <- f
```

**Benchmark results:**
```
Before optimizations:
  1000 containers: 12.3s, 847MB
  10000 containers: 183s, 8.4GB

After optimizations:
  1000 containers: 3.1s, 124MB
  10000 containers: 35s, 980MB

Improvement: 5.2x faster, 8.6x less memory
```

**Implementation steps:**

1. Profile with `go test -cpuprofile=cpu.prof -memprofile=mem.prof`
2. Analyze with `go tool pprof cpu.prof`
3. Identify hot paths (capability checking, control lookups)
4. Pre-compute lookups at package init
5. Add streaming output option to reporters
6. Re-benchmark and compare

**Hints:**
- Use `benchmark_test.go` to measure improvements
- pprof shows exact functions consuming CPU/memory
- Prematurely optimizing is bad, but these are measured bottlenecks
- Trade memory for speed (pre-computed maps) when map is small

### Challenge 4.2: Comprehensive Test Suite

**What to build:**
Achieve 80%+ code coverage with meaningful tests, not just line coverage.

**Test categories:**

1. **Unit tests:** Individual functions in isolation
2. **Integration tests:** Components working together
3. **End-to-end tests:** Full scan workflow
4. **Fuzzing:** Random input handling

**Unit test example:**

File: `internal/rules/capabilities_test.go`
```go
func TestCapabilityRiskLevels(t *testing.T) {
    tests := []struct {
        capability string
        minSeverity finding.Severity
    }{
        {"CAP_SYS_ADMIN", finding.SeverityCritical},
        {"CAP_SYS_PTRACE", finding.SeverityCritical},
        {"CAP_NET_ADMIN", finding.SeverityHigh},
        {"CAP_NET_BIND_SERVICE", finding.SeverityLow},
    }
    
    for _, tt := range tests {
        t.Run(tt.capability, func(t *testing.T) {
            info, exists := GetCapabilityInfo(tt.capability)
            if !exists {
                t.Fatalf("capability %s not found", tt.capability)
            }
            if info.Severity < tt.minSeverity {
                t.Errorf("severity = %v, want >= %v", 
                    info.Severity, tt.minSeverity)
            }
        })
    }
}
```

**Integration test example:**

File: `internal/analyzer/container_test.go`
```go
func TestContainerAnalyzer_PrivilegedDetection(t *testing.T) {
    if testing.Short() {
        t.Skip("skipping integration test")
    }
    
    // Start test Docker container
    ctx := context.Background()
    client, _ := docker.NewClient()
    
    containerID, cleanup := createPrivilegedContainer(t, ctx, client)
    defer cleanup()
    
    // Run analyzer
    analyzer := NewContainerAnalyzer(client)
    findings, err := analyzer.Analyze(ctx)
    
    if err != nil {
        t.Fatalf("Analyze() error = %v", err)
    }
    
    // Verify finding
    var found bool
    for _, f := range findings {
        if f.RuleID == "CIS-5.4" && f.Target.ID == containerID {
            found = true
            if f.Severity != finding.SeverityCritical {
                t.Errorf("severity = %v, want CRITICAL", f.Severity)
            }
        }
    }
    
    if !found {
        t.Error("privileged container not detected")
    }
}

func createPrivilegedContainer(t *testing.T, ctx context.Context, client *docker.Client) (string, func()) {
    resp, err := client.CreateContainer(ctx, &container.Config{
        Image: "alpine:latest",
        Cmd:   []string{"sleep", "3600"},
    }, &container.HostConfig{
        Privileged: true,
    }, nil, nil, "")
    
    if err != nil {
        t.Fatalf("create container: %v", err)
    }
    
    client.StartContainer(ctx, resp.ID, types.ContainerStartOptions{})
    
    cleanup := func() {
        client.StopContainer(ctx, resp.ID, 1)
        client.RemoveContainer(ctx, resp.ID, types.ContainerRemoveOptions{Force: true})
    }
    
    return resp.ID, cleanup
}
```

**End-to-end test example:**

File: `cmd/docksec/main_test.go`
```go
func TestFullScanWorkflow(t *testing.T) {
    // Setup test environment
    client, _ := docker.NewClient()
    ctx := context.Background()
    
    // Create containers with known issues
    privilegedID, _ := createPrivilegedContainer(t, ctx, client)
    noUserID, _ := createRootUserContainer(t, ctx, client)
    defer cleanupContainers(t, ctx, client, privilegedID, noUserID)
    
    // Run scan
    output := runDocksec(t, []string{"scan", "--target", "containers", "--output", "json"})
    
    // Parse JSON output
    var result struct {
        Findings []finding.Finding `json:"findings"`
    }
    json.Unmarshal([]byte(output), &result)
    
    // Verify expected findings
    if len(result.Findings) < 2 {
        t.Errorf("got %d findings, want at least 2", len(result.Findings))
    }
    
    hasPrivileged := false
    hasRootUser := false
    for _, f := range result.Findings {
        if f.RuleID == "CIS-5.4" {
            hasPrivileged = true
        }
        if f.RuleID == "CIS-4.1" {
            hasRootUser = true
        }
    }
    
    if !hasPrivileged {
        t.Error("privileged container not detected")
    }
    if !hasRootUser {
        t.Error("root user not detected")
    }
}

func runDocksec(t *testing.T, args []string) string {
    cmd := exec.Command("./docksec", args...)
    output, err := cmd.CombinedOutput()
    if err != nil {
        t.Fatalf("docksec failed: %v\n%s", err, output)
    }
    return string(output)
}
```

**Fuzzing test example:**

File: `internal/parser/dockerfile_test.go`
```go
func FuzzDockerfileParsing(f *testing.F) {
    // Seed corpus with valid Dockerfiles
    f.Add("FROM alpine\nRUN echo hello")
    f.Add("FROM scratch\nCOPY binary /")
    f.Add("FROM ubuntu:20.04\nUSER nobody")
    
    f.Fuzz(func(t *testing.T, input string) {
        // Should never panic
        result, err := parser.Parse(strings.NewReader(input))
        
        if err != nil {
            return  // Invalid syntax is fine
        }
        
        // If parsed successfully, AST should be valid
        if result.AST == nil {
            t.Error("nil AST with no error")
        }
    })
}
```

Run fuzzing: `go test -fuzz=FuzzDockerfileParsing -fuzztime=1m`

**Coverage measurement:**
```bash
# Generate coverage
go test -coverprofile=coverage.out ./...

# View in browser
go tool cover -html=coverage.out

# Check percentage
go tool cover -func=coverage.out | grep total
```

**Target coverage:**
- Rules package: 90% (pure logic, easy to test)
- Analyzers: 75% (Docker integration, some paths hard to test)
- Scanner: 80% (orchestration logic)
- Reporter: 85% (output formatting)
- Overall: 80%

**Implementation steps:**

1. Add unit tests for all rule packages
2. Add integration tests requiring Docker (use build tags)
3. Add e2e tests in cmd/ package
4. Add fuzzing for parsers
5. Set up CI to fail if coverage drops below 75%

**Hints:**
- Use table-driven tests (easier to add cases)
- Mock Docker client for unit tests (testify/mock)
- Use build tags to separate integration tests: `// +build integration`
- golden files for expected outputs (terminal reporter)

### Challenge 4.3: Kubernetes Support

**What to build:**
Extend scanner to work with Kubernetes pods, analyzing containers via K8s API instead of Docker API.

**Why it matters:**
Production deployments use Kubernetes. Need to scan pods, check Pod Security Standards, validate security contexts.

**Kubernetes-specific checks:**

1. Pod running as privileged
2. hostNetwork, hostPID, hostIPC enabled
3. Capabilities added beyond defaults
4. securityContext missing or permissive
5. Service accounts with excessive permissions
6. Pod Security Standards violations

**Where to start:**
Create `internal/k8s/` package with Kubernetes client wrapper.
```go
// internal/k8s/client.go
import (
    "k8s.io/client-go/kubernetes"
    "k8s.io/client-go/rest"
)

type Client struct {
    clientset *kubernetes.Clientset
}

func NewClient() (*Client, error) {
    // In-cluster config (when running as pod)
    config, err := rest.InClusterConfig()
    if err != nil {
        // Fallback to kubeconfig
        config, err = clientcmd.BuildConfigFromFlags("", kubeconfig)
    }
    
    clientset, err := kubernetes.NewForConfig(config)
    return &Client{clientset: clientset}, nil
}
```

**Create Kubernetes analyzer:**

File: `internal/analyzer/kubernetes.go`
```go
type KubernetesAnalyzer struct {
    client *k8s.Client
}

func (a *KubernetesAnalyzer) Analyze(ctx context.Context) (finding.Collection, error) {
    pods, err := a.client.ListPods(ctx, metav1.ListOptions{})
    if err != nil {
        return nil, err
    }
    
    var findings finding.Collection
    for _, pod := range pods.Items {
        findings = append(findings, a.analyzePod(pod)...)
    }
    
    return findings, nil
}

func (a *KubernetesAnalyzer) analyzePod(pod v1.Pod) finding.Collection {
    var findings finding.Collection
    
    target := finding.Target{
        Type: finding.TargetPod,
        Name: pod.Namespace + "/" + pod.Name,
        ID:   string(pod.UID),
    }
    
    // Check pod-level security context
    if pod.Spec.HostNetwork {
        f := finding.New("K8S-PSS-BASELINE", "Pod uses host network", 
            finding.SeverityHigh, target).
            WithDescription("hostNetwork: true gives pod access to host's network stack.")
        findings = append(findings, f)
    }
    
    // Check each container
    for _, container := range pod.Spec.Containers {
        findings = append(findings, a.analyzeContainer(target, container)...)
    }
    
    return findings
}

func (a *KubernetesAnalyzer) analyzeContainer(
    podTarget finding.Target, 
    container v1.Container,
) finding.Collection {
    var findings finding.Collection
    
    // Check security context
    if container.SecurityContext != nil {
        if container.SecurityContext.Privileged != nil && 
           *container.SecurityContext.Privileged {
            f := finding.New("K8S-PRIVILEGED", "Privileged container in pod", 
                finding.SeverityCritical, podTarget).
                WithDescription("Container " + container.Name + " runs as privileged.")
            findings = append(findings, f)
        }
        
        // Check capabilities
        if container.SecurityContext.Capabilities != nil {
            for _, cap := range container.SecurityContext.Capabilities.Add {
                capInfo, exists := rules.GetCapabilityInfo(string(cap))
                if exists && capInfo.Severity >= finding.SeverityHigh {
                    f := finding.New("K8S-CAP-ADD", "Dangerous capability added",
                        capInfo.Severity, podTarget).
                        WithDescription("Container " + container.Name + 
                            " adds capability " + string(cap))
                    findings = append(findings, f)
                }
            }
        }
    }
    
    // Check if running as root
    if container.SecurityContext == nil || 
       container.SecurityContext.RunAsNonRoot == nil ||
       !*container.SecurityContext.RunAsNonRoot {
        f := finding.New("K8S-ROOT-USER", "Container may run as root",
            finding.SeverityMedium, podTarget).
            WithDescription("Container " + container.Name + 
                " does not enforce non-root user.")
        findings = append(findings, f)
    }
    
    return findings
}
```

**Pod Security Standards mapping:**
```go
// internal/k8s/pss.go
type PodSecurityStandard string

const (
    PSSPrivileged PodSecurityStandard = "privileged"
    PSSBaseline   PodSecurityStandard = "baseline"
    PSSRestricted PodSecurityStandard = "restricted"
)

func EvaluatePSS(pod v1.Pod) (PodSecurityStandard, []string) {
    violations := []string{}
    
    // Privileged: no restrictions
    // Baseline: minimal restrictions
    // Restricted: hardened configuration
    
    // Check baseline violations
    if pod.Spec.HostNetwork {
        violations = append(violations, "hostNetwork must be false")
    }
    if pod.Spec.HostPID {
        violations = append(violations, "hostPID must be false")
    }
    if pod.Spec.HostIPC {
        violations = append(violations, "hostIPC must be false")
    }
    
    // If baseline violated, return baseline
    if len(violations) > 0 {
        return PSSBaseline, violations
    }
    
    // Check restricted violations
    for _, container := range pod.Spec.Containers {
        if container.SecurityContext == nil {
            violations = append(violations, container.Name + ": missing securityContext")
            continue
        }
        
        if container.SecurityContext.AllowPrivilegeEscalation == nil ||
           *container.SecurityContext.AllowPrivilegeEscalation {
            violations = append(violations, container.Name + 
                ": allowPrivilegeEscalation must be false")
        }
        
        if container.SecurityContext.RunAsNonRoot == nil ||
           !*container.SecurityContext.RunAsNonRoot {
            violations = append(violations, container.Name + 
                ": runAsNonRoot must be true")
        }
        
        if container.SecurityContext.SeccompProfile == nil ||
           container.SecurityContext.SeccompProfile.Type != v1.SeccompProfileTypeRuntimeDefault {
            violations = append(violations, container.Name + 
                ": seccompProfile must be RuntimeDefault")
        }
    }
    
    if len(violations) > 0 {
        return PSSRestricted, violations
    }
    
    return PSSRestricted, nil
}
```

**CLI integration:**
```go
// cmd/docksec/main.go
func newScanCmd(cfg *config.Config) *cobra.Command {
    cmd := &cobra.Command{
        Use:   "scan",
        Short: "Scan containers for security issues",
        RunE:  runScan,
    }
    
    flags := cmd.Flags()
    flags.StringSliceVarP(&cfg.Targets, "target", "t", []string{"all"},
        "Scan targets: docker, kubernetes, all")
    flags.BoolVar(&cfg.K8sEnabled, "k8s", false, "Enable Kubernetes scanning")
    flags.StringVar(&cfg.Kubeconfig, "kubeconfig", "", "Path to kubeconfig")
    
    return cmd
}
```

**Example output:**
```
Scanning Kubernetes cluster...
Namespace: default

[CRITICAL] Privileged container in pod
  Pod: default/nginx-deployment-7d6c4f8b9-x7k2m
  Container: nginx
  CIS Control: K8S-PRIVILEGED
  Remediation: Remove privileged: true from securityContext

[HIGH] Pod uses host network
  Pod: default/monitoring-agent-dw8qz
  PSS Violation: Baseline
  Remediation: Set hostNetwork: false

[MEDIUM] Container may run as root
  Pod: default/web-app-5b8c9d6f4-mz3lp
  Container: app
  PSS Violation: Restricted
  Remediation: Set securityContext.runAsNonRoot: true

Summary:
  Pods scanned: 47
  PSS Restricted: 12
  PSS Baseline: 23
  PSS Privileged: 12
  Total findings: 89
```

**Implementation steps:**

1. Add k8s.io/client-go dependency
2. Create k8s client wrapper
3. Implement Kubernetes analyzer
4. Add PSS evaluation logic
5. Extend Target type for pods
6. Add K8s-specific CIS controls

**Hints:**
- Use k8s.io/client-go v0.28.0 or later
- Handle both in-cluster and kubeconfig authentication
- Pod security context is different from container security context
- Some checks apply to pod, some to containers
- Watch for nil pointer dereference (many K8s fields are pointers)

**Going deeper:**
- Add NetworkPolicy analysis (check for default deny)
- Scan PodSecurityPolicy/PodSecurityAdmission configs
- Check RBAC permissions (overly permissive service accounts)
- Validate admission controller configurations
- Scan Helm charts before deployment

## Bonus Challenges

### Bonus 1: CVE Scanning Integration

Integrate with Trivy or Grype to add vulnerability scanning.

### Bonus 2: Compliance Report Generator

Generate compliance reports for SOC2, PCI-DSS, HIPAA based on findings.

### Bonus 3: Machine Learning Anomaly Detection

Use ML to detect containers behaving abnormally compared to historical patterns.

### Bonus 4: Docker Compose Graph Analyzer

Build dependency graph from compose files, detect circular dependencies and over-permissive network configurations.

### Bonus 5: Browser Extension

Create browser extension that runs docksec when viewing Dockerfiles on GitHub.

## Getting Help

**Stuck on a challenge?**

1. Check the existing code for similar patterns
2. Read Docker SDK documentation: https://pkg.go.dev/github.com/docker/docker
3. Review CIS Docker Benchmark: https://www.cisecurity.org/benchmark/docker
4. Look at similar tools: Docker Bench, Trivy, Falco source code

**Found a bug while implementing?**

That's part of the learning process. Debug it:
- Add log statements in analyzer
- Run with --verbose flag
- Use `docker inspect` to verify expected values
- Check Docker daemon logs: `journalctl -u docker`

**Want to contribute your solution?**

Write clean code, add tests, update documentation. These challenges make good portfolio projects.
