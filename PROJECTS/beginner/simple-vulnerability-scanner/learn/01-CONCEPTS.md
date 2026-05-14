# Core Security Concepts

This document explains the security concepts you'll encounter while building angela. These are not just definitions. We'll dig into why they matter and how they actually work in production systems.

## Supply Chain Attacks

### What It Is

A supply chain attack targets the dependencies your code relies on rather than your code itself. An attacker compromises a package you import, and that malicious code runs with the same privileges as your application. The attack succeeds because developers trust their dependencies without auditing them.

### Why It Matters

The 2020 SolarWinds breach compromised over 18,000 organizations including Microsoft, Intel, and most of the US federal government. The attackers didn't hack SolarWinds directly. They injected malicious code into the Orion software build process, and every customer who updated Orion installed a backdoor. The code was signed with SolarWinds' certificate, so it looked legitimate.

In the Python ecosystem, the 2022 PyTorch supply chain attack worked the same way. Someone uploaded a malicious package called `torchtriton` to PyPI. The legitimate `torch` package depends on `triton`, but pip's dependency resolver will accept `torchtriton` if it has a higher version number. Users running `pip install torch` during a specific window got the malicious package, which stole AWS credentials and SSH keys.

### How It Works

Supply chain attacks exploit three main vectors:

**Dependency confusion**: Upload a malicious package to a public registry with the same name as an internal package. If pip checks PyPI before your private index, it downloads the public malicious version. This happened to Apple, Microsoft, and Netflix in 2021 when researcher Alex Birsan uploaded packages matching their internal names.

**Typosquatting**: Register packages with names similar to popular ones (`requsts` instead of `requests`). Developers make typos, pip installs the wrong package, game over. In 2017, someone uploaded `python3-dateutil` to PyPI. The real package is `python-dateutil`. The fake one had 2,000 downloads before removal.

**Package takeover**: Compromise a maintainer's account or exploit abandoned packages. The `ua-parser-js` incident (8 million weekly downloads) happened when someone stole the maintainer's npm credentials. The `event-stream` package was handed over to a new "maintainer" who pushed backdoored code targeting cryptocurrency wallets.

### Common Attacks

1. **Malicious code in setup.py** - Python packages run arbitrary code during installation. A malicious `setup.py` can steal credentials before the package even gets imported.

2. **Backdoored dependencies** - The malicious package itself might be clean, but it depends on something malicious. Transitive dependencies create a deep attack surface.

3. **Version pinning bypasses** - You pin `requests==2.28.0`, but pip might still install `requests[security]==2.28.0` which has different dependencies. The extras syntax creates an escape hatch.

### Defense Strategies

angela implements several defenses:

- **Version pinning with >= constraints** - `requests>=2.28.0` means "at least this version", giving you security patches while preventing downgrades. This is what `internal/pyproject/parser.go:88-97` extracts.

- **Vulnerability scanning** - Query OSV.dev for known CVEs in your dependency tree. angela does this in `internal/osv/client.go:40-65`, batching requests to avoid hammering the API.

- **Signature verification** - Not implemented in angela (beginner project), but production tools verify package checksums against a known-good hash. PyPI provides SHA256 hashes for every release.

The best defense is **reducing your dependency count**. Every package you import is a potential supply chain vector. angela itself has only 5 direct dependencies (fatih/color, pelletier/go-toml, spf13/cobra, golang.org/x/sync).

## CVE Databases

### What It Is

CVE (Common Vulnerabilities and Exposures) is a standardized format for documenting security bugs. Each vulnerability gets a unique ID like `CVE-2023-32681`. The MITRE Corporation maintains the CVE system, but multiple organizations contribute data: GitHub Security Advisories, NIST's National Vulnerability Database, vendor-specific databases.

OSV.dev (Open Source Vulnerabilities) aggregates all of these into a single queryable API. It covers PyPI, npm, Maven, Go, and more. Instead of querying 10 different databases, angela queries OSV once.

### Why It Matters

On April 14, 2023, CVE-2023-32681 was published for the `requests` library. Versions before 2.31.0 allow attackers to inject arbitrary headers via `\r\n` characters in the Proxy-Authorization header. This bypasses proxy restrictions and can leak sensitive cookies.

If you're running `requests==2.28.0`, you're vulnerable. But how would you even know about CVE-2023-32681? You'd have to subscribe to GitHub Security Advisories, monitor PyPI's announcements, check the NIST NVD regularly, and cross-reference everything against your dependencies. OSV.dev automates this.

### How It Works

OSV.dev provides a batch query endpoint that accepts multiple package+version pairs:

```json
{
  "queries": [
    {"package": {"name": "requests", "ecosystem": "PyPI"}, "version": "2.28.0"},
    {"package": {"name": "django", "ecosystem": "PyPI"}, "version": "3.2.0"}
  ]
}
```

The response includes all known vulnerabilities for those exact versions:

```json
{
  "results": [
    {"vulns": [{"id": "GHSA-j8r2-6x86-q33q", "modified": "2023-05-22T20:30:00Z"}]},
    {"vulns": [{"id": "CVE-2023-31047", "modified": "2023-05-03T12:00:00Z"}]}
  ]
}
```

angela then fetches full details for each vulnerability ID to get the summary, severity, and fixed version. This two-step process (batch query + individual fetches) is in `internal/osv/client.go:40-95`.

### Common Pitfalls

**Mistake 1: Checking only direct dependencies**
```go
// Bad: only scans packages explicitly in pyproject.toml
for _, dep := range directDeps {
    checkVulns(dep)
}

// Good: would need to resolve the entire dependency tree
// (angela doesn't do this - it's a beginner project limitation)
```

Transitive dependencies are where most CVEs hide. `requests` depends on `urllib3`, which depends on `certifi`. A vulnerability in `certifi` affects your app even though you never imported it directly. Full supply chain scanning requires building the complete dependency graph, which angela doesn't do (see 04-CHALLENGES.md for how to add this).

**Mistake 2: Trusting the severity field blindly**

OSV sometimes has no severity data, reports "UNKNOWN", or uses different scoring systems (CVSS v3 vs v4 vs GitHub's internal scale). angela extracts severity in `internal/osv/client.go:245-270`:

```go
func extractSeverity(v *osvVuln) string {
    for _, s := range v.Severity {
        if s.Type != "CVSS_V3" && s.Type != "CVSS_V4" {
            continue  // Skip non-standard scoring
        }
        if score, err := strconv.ParseFloat(s.Score, 64); err == nil {
            return classifyScore(score)  // Map 0-10 to severity names
        }
    }
    // Fallback to database_specific.severity or "UNKNOWN"
}
```

Always have a fallback. Some GitHub advisories use qualitative labels ("MODERATE") instead of numeric CVSS scores.

**Mistake 3: Not deduplicating CVE/GHSA aliases**

The same vulnerability gets multiple IDs:
- CVE-2023-32681 (MITRE's ID)
- GHSA-j8r2-6x86-q33q (GitHub's ID)
- PYSEC-2023-80 (PyPA's ID)

OSV returns all three. If you naively count them, you'll report "3 vulnerabilities" when it's really one issue with three names. angela deduplicates in `internal/osv/client.go:141-149`:

```go
func isDuplicate(v *osvVuln, seen map[string]bool) bool {
    if seen[v.ID] {
        return true
    }
    for _, alias := range v.Aliases {
        if seen[alias] {
            return true  // Already saw this vuln under a different ID
        }
    }
    return false
}
```

## PEP 440 Version Resolution

### What It Is

PEP 440 defines how Python package versions are structured and compared. It's **not** semantic versioning. Python versions support epochs, pre-releases (alpha/beta/rc), post-releases, dev releases, and local version identifiers. The full grammar is:

```
[epoch!]release[.pre-release][.post-release][.dev-release][+local]
```

Real examples:
- `2!1.0` - Epoch 2, release 1.0 (beats all epoch 0 or 1 versions)
- `1.0a1` - Alpha pre-release
- `1.0.post3` - Post-release (stable, just a minor fix)
- `1.0.dev5` - Development snapshot
- `1.0+ubuntu2` - Local version label

### Why It Matters

If you sort versions as strings, you get this wrong:

```
"1.0a1" > "1.0"   # WRONG: "a" > "" in ASCII
"1.10.0" < "1.9.0"  # WRONG: string comparison not numeric
```

Pip uses PEP 440 comparison to determine "latest version". If angela sorts incorrectly, it might upgrade users to an unstable pre-release or skip important security patches.

In March 2023, someone uploaded `certifi==2023.03.07a1` to PyPI (an accidental pre-release). Tools that didn't implement PEP 440 correctly tried to upgrade users from the stable `2023.02.23` to the pre-release `2023.03.07a1`, breaking builds.

### How It Works

angela's PEP 440 parser in `internal/pypi/version.go:60-112` uses a single compiled regex to extract all components:

```
(?i)^v?
(?:(\d+)!)?                          # epoch
(\d+(?:\.\d+)*)                      # release segments
(?:[-_.]?(alpha|a|beta|b|rc)[-_.]?(\d*))?  # pre-release
(?:[-_.]?(post|rev|r)[-_.]?(\d*)|-(\d+))?  # post-release
(?:[-_.]?(dev)[-_.]?(\d*))?          # dev release
(?:\+([a-z0-9]...))?$                # local version
```

The comparison function implements PEP 440's ordering rules:

```
1.0.dev1 < 1.0a1 < 1.0b1 < 1.0rc1 < 1.0 < 1.0.post1
```

This is done using sentinel values (`math.MinInt` and `math.MaxInt`) in `internal/pypi/version.go:146-174`:

```go
func preKey(v Version) (int, int) {
    hasPre := v.PreKind != ""
    hasDev := v.Dev >= 0
    hasPost := v.Post >= 0

    switch {
    case !hasPre && !hasPost && hasDev:
        return math.MinInt, math.MinInt  // Dev-only sorts first
    case hasPre:
        return preKindRank(v.PreKind), v.PreNum  // a=0, b=1, rc=2
    default:
        return math.MaxInt, math.MaxInt  // Final releases sort last
    }
}
```

### Common Attacks

PEP 440 version resolution doesn't have "attacks" per se, but there are exploitable behaviors:

1. **Pre-release confusion** - An attacker uploads `malicious-package==2.0a1`. If a user has `malicious-package>=1.0` in their dependencies and their resolver doesn't filter pre-releases, they get the alpha version.

2. **Epoch bumping** - Epochs override everything else. `1!1.0` beats `9999.0.0` because epoch 1 > epoch 0. This is intended for emergency package renames, but a malicious actor could abuse it.

3. **Local version labels** - `1.0+evil` doesn't appear on PyPI (local versions can't be uploaded), but if someone's private index serves it, it sorts after `1.0` and might get installed.

### Defense Strategies

angela's approach:

- **Filter pre-releases by default** - `internal/pypi/version.go:208-220` has `LatestStable()` which skips anything with `PreKind != ""` or `Dev >= 0`.

- **Explicit pre-release opt-in** - The `--include-prerelease` flag lets users deliberately get alpha/beta versions when testing.

- **Epoch awareness** - The parser handles epochs correctly. If you see `2!1.0`, angela won't incorrectly assume `1.0` is newer.

The key is never assuming versions are simple major.minor.patch. Python packages in the wild use the full PEP 440 grammar, and if your parser doesn't handle it, you're going to make bad decisions.

## How These Concepts Relate

Supply chain attacks target the dependency resolution process. An attacker exploits version confusion (PEP 440) to get pip to install a malicious package. CVE databases detect known vulnerabilities after the fact, but they can't catch zero-days or intentional backdoors. You need both: version pinning to control what gets installed, and vulnerability scanning to know when an installed version is compromised.

```
┌─────────────────┐
│  pyproject.toml │  ← Your dependencies
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Version Parsing │  ← PEP 440 determines "latest"
│  (PEP 440)      │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  CVE Database   │  ← Check if "latest" is vulnerable
│  (OSV.dev)      │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Risk Assessment │  ← Should we upgrade? Skip? Ignore?
└─────────────────┘
```

All three work together. Miss one and you have blind spots.

## Industry Standards and Frameworks

### OWASP Top 10

This project addresses:

- **A06:2021 - Vulnerable and Outdated Components** - angela scans for known CVEs and outdated packages. This is OWASP's #6 most critical web application risk. The 2017 Equifax breach (143 million records stolen) happened because they ran an outdated version of Apache Struts with a known RCE vulnerability.

- **A08:2021 - Software and Data Integrity Failures** - Supply chain attacks like dependency confusion fall here. angela helps by showing you exactly what versions you're running, but it doesn't verify package signatures (that would require checking PyPI's PGP keys).

### MITRE ATT&CK

Relevant techniques:

- **T1195.001 - Compromise Software Dependencies** - The SolarWinds and PyTorch attacks both used this. Attackers inject malicious code into a package your build process downloads. angela detects known compromises via OSV.dev, but can't catch zero-days.

- **T1195.002 - Compromise Software Supply Chain** - Broader than just dependencies. Includes compromising build servers, signing certificates, and distribution infrastructure. angela addresses the dependency piece.

### CWE

Common weakness enumerations covered:

- **CWE-1104** - Use of Unmaintained Third-Party Components. If you're running `django==2.2`, you're on a version that went EOL in April 2022. angela flags this by showing available updates.

- **CWE-829** - Inclusion of Functionality from Untrusted Control Sphere. Every `pip install` from PyPI trusts that package's code. angela doesn't solve this (you'd need code review or sandboxing), but it at least tells you what you're trusting.

## Real World Examples

### Case Study 1: Equifax Breach (2017)

**What happened**: Equifax ran Apache Struts with a known RCE vulnerability (CVE-2017-5638, published March 2017). Attackers exploited it in May 2017, stealing 143 million Social Security numbers, birth dates, and addresses.

**How the attack worked**: The vulnerability was in Struts' file upload parser. An attacker sent a crafted `Content-Type` header that triggered remote code execution. Equifax had **two months** between the CVE publication and the breach to patch.

**What defenses failed**: Equifax didn't have automated vulnerability scanning. They relied on manual security audits, which missed the outdated Struts version. Even after the breach started, it took them **six weeks** to detect it.

**How this could have been prevented**: Automated scanning (what angela does) would have flagged CVE-2017-5638 immediately. If Equifax had a policy of "patch critical CVEs within 72 hours", the breach wouldn't have happened.

### Case Study 2: event-stream Backdoor (2018)

**What happened**: A popular npm package called `event-stream` (2 million downloads/week) was handed over to a new maintainer who immediately pushed a backdoored version. The malicious code targeted cryptocurrency wallets, stealing Bitcoin private keys.

**How the attack worked**: The original maintainer was overwhelmed and accepted a volunteer's offer to take over. The new "maintainer" added a dependency on `flatmap-stream@0.1.1`, which contained obfuscated code that checked if the application was Copay (a Bitcoin wallet). If yes, it exfiltrated wallet keys.

**What defenses failed**: The package had no continuous vulnerability scanning. Developers trusted the maintainer's account without verifying identity. npm didn't flag the suspicious dependency add.

**How this could have been prevented**: Dependency review (what version did we have last week vs this week?) would have caught the sudden `flatmap-stream` addition. angela doesn't do continuous monitoring (yet), but [04-CHALLENGES.md](./04-CHALLENGES.md) has ideas for adding it.

## Testing Your Understanding

Before moving to the architecture, make sure you can answer:

1. You see a package dependency `requests>=2.28.0`. What vulnerabilities could this miss compared to `requests==2.31.0`? (Hint: anything between 2.28.0 and 2.31.0)

2. A new package `requests-security==3.0.0` appears on PyPI. Your app imports `requests`. Should you worry? (Hint: yes. Dependency confusion attack via typosquatting)

3. OSV returns CVE-2023-1234, GHSA-abcd-efgh, and PYSEC-2023-001 for the same package. How many distinct vulnerabilities is this? (Hint: one vulnerability, three IDs)

If these questions feel unclear, re-read the relevant sections. The implementation will make more sense once these fundamentals click.

## Further Reading

**Essential:**
- [PEP 440 - Version Identification](https://peps.python.org/pep-0440/) - The full spec for Python version strings. angela implements the core parts.
- [OSV.dev API Documentation](https://osv.dev/docs/) - How to query the vulnerability database. angela uses the batch endpoint.

**Deep dives:**
- [Backstabber's Knife Collection](https://arxiv.org/abs/2005.09535) - Academic paper analyzing malicious packages on PyPI. Found 174 malicious packages using typosquatting.
- [Dependency Confusion: When Are Your npm Packages Vulnerable?](https://medium.com/@alex.birsan/dependency-confusion-4a5d60fec610) - Alex Birsan's writeup of the attack that hit Apple, Microsoft, and others.

**Historical context:**
- [The Internet Worm (1988)](https://spaf.cerias.purdue.edu/tech-reps/823.pdf) - Robert Morris's worm exploited a buffer overflow in `fingerd`. First major supply chain-style attack using trusted system services.
- [Reflections on Trusting Trust](https://www.cs.cmu.edu/~rdriley/487/papers/Thompson_1984_ReflectionsonTrustingTrust.pdf) - Ken Thompson's 1984 Turing Award lecture on compiler backdoors. Relevant to understanding why you can't fully trust upstream code.
