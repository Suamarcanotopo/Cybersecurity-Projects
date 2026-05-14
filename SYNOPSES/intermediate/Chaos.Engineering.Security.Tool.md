# Chaos Engineering Security Tool

## Overview
Build a security-focused chaos engineering platform in Go that injects controlled security failures into running infrastructure to test whether defensive controls survive real-world disruptions. Traditional chaos engineering tests availability, but this tool tests security resilience by simulating certificate expiry, DNS manipulation, credential rotation during active sessions, firewall rule changes, and authentication service downtime. This project teaches the intersection of reliability engineering and security engineering, revealing hidden dependencies and single points of failure that only appear under stress.

## Step-by-Step Instructions
1. **Set up the Go project and experiment framework** Create a Go module with an experiment-based architecture inspired by the Chaos Toolkit specification. Define an Experiment interface with Hypothesis, Inject, Verify, and Rollback methods. Each experiment declares a steady-state hypothesis (what should remain true during the failure), injects the failure, verifies whether the hypothesis held, and cleans up. Build a CLI using cobra with subcommands for each experiment type. Implement a safety system that requires explicit confirmation before injection and automatically triggers rollback after a configurable timeout.

2. **Build the TLS and certificate chaos experiments** Implement three certificate-related experiments: simulate certificate expiry by deploying a self-signed cert with a past expiration date to a test Nginx instance, simulate certificate revocation by adding a certificate serial to a local CRL and testing whether clients check revocation status, and simulate a CA compromise by replacing the trusted CA certificate with a different one mid-connection. Each experiment tests whether the application properly validates certificates, rejects expired or revoked certs, and surfaces clear error messages rather than silently falling back to insecure connections.

3. **Create DNS manipulation experiments** Build experiments that simulate DNS-layer disruptions: redirect a service hostname to a different IP, introduce DNS resolution delays of 5 to 30 seconds, return NXDOMAIN for authentication service domains, and modify DNS cache entries for certificate validation endpoints like OCSP responders. Use a local CoreDNS instance that you can programmatically reconfigure. Verify whether applications detect the manipulation, fall back gracefully, or silently connect to incorrect endpoints.

4. **Implement credential rotation chaos** Build experiments that test credential rotation resilience: rotate a database password while the application has active connections, expire all active JWT tokens simultaneously by simulating a signing key rotation, revoke an API key that a service is actively using, and rotate TLS client certificates during mutual TLS sessions. The hypothesis for each is that the application should detect the credential failure, obtain new credentials, and recover without data loss or extended downtime. Measure recovery time and whether any requests were served with stale credentials.

5. **Build firewall and network security experiments** Create experiments that modify network security controls: drop all traffic to a specific port simulating firewall misconfiguration, block outbound connections to authentication providers, introduce packet corruption on encrypted channels, and restrict network to allow only specific IP ranges. Use iptables or nftables commands executed via Go os/exec. Each experiment should verify that the application fails closed (denies access) rather than fails open (allows unauthenticated access) when security infrastructure is disrupted.

6. **Implement authentication service chaos** Build experiments specifically targeting authentication flows: shut down the OAuth provider while users have active sessions, introduce latency into LDAP or AD responses causing timeouts, return malformed responses from the token validation endpoint, and exhaust the authentication service connection pool. Test whether the application caches authentication decisions and for how long, whether it queues or rejects requests during auth outages, and whether it exposes any authentication bypass when the auth service is unavailable.

7. **Create the observation and measurement system** Build a real-time observation system that collects metrics during experiments: application response codes, authentication success and failure rates, error log entries, certificate validation outcomes, and network connection states. Use Prometheus client libraries to expose metrics and create pre-built Grafana dashboards that visualize security posture during chaos injection. Generate post-experiment reports that show the timeline of injection, impact, detection, and recovery with specific timestamps.

8. **Build the experiment orchestrator and CI integration** Create an orchestrator that can run multiple experiments in sequence or parallel with configurable blast radius (single service, single host, entire environment). Implement a plan mode that shows what would happen without injecting anything. Build a GitHub Actions integration that runs security chaos experiments as part of the CI/CD pipeline, failing the build if any experiment causes a security regression like failing open. Include Docker Compose files that set up a complete test environment with sample services, an auth provider, DNS, and TLS termination.

## Key Concepts to Learn
- Chaos engineering principles applied to security controls
- TLS certificate lifecycle and validation chain mechanics
- DNS security and the impact of DNS manipulation on authentication
- Credential rotation strategies and graceful degradation
- Fail-closed vs fail-open behavior in security systems
- Network security control dependencies and single points of failure
- Observability and measurement during security incidents
- Security testing integration in CI/CD pipelines

## Deliverables
- Go CLI tool with pluggable experiment framework and safety controls
- Four experiment categories: TLS, DNS, credentials, firewall, and authentication
- Real-time observation system with Prometheus metrics and Grafana dashboards
- Post-experiment reports with timeline visualization
- Experiment orchestrator with blast radius control and plan mode
- GitHub Actions integration for CI/CD security chaos testing
- Docker Compose test environment with sample services
