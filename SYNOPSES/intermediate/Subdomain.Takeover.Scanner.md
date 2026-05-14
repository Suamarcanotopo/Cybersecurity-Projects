# Subdomain Takeover Scanner

## Overview
Build a subdomain takeover detection tool in Go that enumerates subdomains via certificate transparency logs and DNS brute force, then checks each for dangling DNS records pointing to unclaimed cloud resources. Subdomain takeover is one of the most common findings in bug bounty programs because companies frequently decommission services without cleaning up DNS records, leaving CNAME entries pointing to S3 buckets, GitHub Pages, Heroku apps, and other cloud resources that anyone can claim. This project teaches DNS mechanics, cloud service provisioning patterns, and one of the most practical and rewarding areas of bug bounty hunting.

## Step-by-Step Instructions
1. **Set up the Go project and subdomain enumeration** Create a Go module with a pipeline architecture: enumerate, resolve, fingerprint, and check. Build two subdomain enumeration methods: certificate transparency log querying (using crt.sh and Censys CT APIs to find all certificates issued for a domain and its subdomains) and DNS brute force (iterating through a wordlist of common subdomain names and querying DNS). Merge results from both methods and deduplicate. Use goroutines with a worker pool for concurrent DNS resolution. Implement the CLI using `cobra` with flags for target domain, wordlist path, concurrency level, and output format.

2. **Build the DNS resolution and record analysis engine** For each discovered subdomain, perform comprehensive DNS resolution: query for A, AAAA, CNAME, MX, TXT, and NS records. The critical record for takeover detection is the CNAME — if a subdomain has a CNAME pointing to an external service, it is a potential takeover candidate. Build a DNS client using `miekg/dns` for low-level control over DNS queries. Implement DNS caching to avoid redundant lookups. Handle DNS wildcards (detect if the parent domain returns results for any subdomain) to filter out false positives. Store all DNS records in a structured format for analysis.

3. **Implement cloud service fingerprinting** Build fingerprint modules for the most commonly affected cloud services: AWS S3 (CNAME to `*.s3.amazonaws.com` returning "NoSuchBucket"), GitHub Pages (CNAME to `*.github.io` returning 404 with GitHub's error page), Heroku (CNAME to `*.herokuapp.com` returning "No such app"), Azure (CNAME to `*.azurewebsites.net`, `*.cloudapp.net`, `*.trafficmanager.net`), Netlify (CNAME to `*.netlify.app`), Shopify (CNAME to `shops.myshopify.com`), and Fastly (CNAME to `*.fastly.net`). Each fingerprint module should resolve the CNAME target, make an HTTP request, and check the response for indicators that the resource is unclaimed.

4. **Build the HTTP-based takeover verification** For each potential takeover candidate identified by DNS analysis, perform HTTP verification: connect to the subdomain, follow redirects, and analyze the response status code, headers, and body content. Match response content against known takeover signatures: specific error pages (S3's XML error, GitHub's 404, Heroku's "no such app"), specific HTTP status codes, and specific response headers. Implement both HTTP and HTTPS checks since some services behave differently. Build a confidence scoring system: high confidence (service returns a definitive unclaimed response), medium (service returns a generic error that might indicate other issues), low (DNS points to the service but HTTP check is inconclusive).

5. **Add advanced enumeration techniques** Implement additional subdomain discovery methods: zone transfer attempts (AXFR query — rarely works but free to try), DNS record permutation (prepend/append common words to known subdomains: dev-, staging-, -api, -admin), search engine dorking via API (site:*.target.com), and Wayback Machine historical URL mining for subdomains. Build an integration layer that combines results from all enumeration sources with deduplication and source tracking. The more subdomains you enumerate, the higher the chance of finding a takeover.

6. **Implement notification and proof-of-concept generation** When a likely takeover is detected, generate a proof-of-concept report for each finding: the subdomain, the CNAME target, the cloud service identified, the HTTP response evidence, and step-by-step instructions for claiming the resource (e.g., "Create an S3 bucket named X in region Y"). Implement notification via webhook (Slack, Discord) for real-time alerting during long scans. For verified high-confidence findings, generate a markdown report suitable for bug bounty submission with all required evidence. Include a disclaimer about responsible disclosure and only claiming resources on domains you own.

7. **Build continuous monitoring mode** Implement a monitoring mode that periodically re-checks known subdomains for new takeover opportunities. Store scan history in SQLite and detect changes: a subdomain that was previously safe now has a dangling CNAME (perhaps the service was decommissioned), or a previously vulnerable subdomain has been fixed. Implement differential reporting that shows only changes since the last scan. Add a watch mode for specific high-value domains that checks more frequently. This is how bug bounty hunters maintain ongoing coverage of their target scope.

8. **Add output formatting and integration testing** Implement multiple output formats: JSON (for toolchain integration), CSV (for spreadsheets), markdown (for reports), and a formatted terminal table with color-coded severity. Build a comprehensive test suite using mock DNS responses and mock HTTP servers that simulate each cloud service's takeover-vulnerable response. Test edge cases: wildcard DNS domains, CNAME chains (CNAME pointing to another CNAME), services that intermittently return error pages, and rate-limited DNS resolvers. Document the tool's usage, legal considerations (only scan domains you have authorization to test), and how to responsibly disclose takeover vulnerabilities.

## Key Concepts to Learn
- DNS record types and CNAME resolution mechanics
- Certificate transparency logs and their role in subdomain discovery
- Cloud service provisioning and resource claiming patterns
- Subdomain takeover vulnerability mechanics across cloud providers
- Bug bounty methodology and responsible disclosure practices
- DNS brute force techniques and wordlist optimization
- Continuous security monitoring and change detection
- Proof-of-concept documentation for vulnerability reports

## Deliverables
- Go CLI tool with concurrent subdomain enumeration pipeline
- Certificate transparency and DNS brute force enumeration modules
- Cloud service fingerprinting for seven major providers
- HTTP-based takeover verification with confidence scoring
- Continuous monitoring mode with change detection and alerting
- Proof-of-concept report generator for bug bounty submissions
- Comprehensive test suite with mock DNS and HTTP responses
- Documentation covering legal requirements and responsible disclosure
