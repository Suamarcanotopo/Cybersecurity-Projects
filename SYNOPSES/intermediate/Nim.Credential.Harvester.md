# Nim Credential Harvester

## Overview
Build a credential hygiene auditing tool in Nim that scans a Linux system for improperly stored secrets and generates a security posture report. Nim is increasingly adopted by security professionals because it compiles to small, dependency-free native binaries. This project teaches where applications and users commonly store credentials on Linux systems, why those default storage locations are insecure, and how penetration testers identify exposed secrets during authorized engagements. You will build the same type of reconnaissance tool used in professional security assessments while learning a language valued in the offensive security community.

## Step-by-Step Instructions
1. **Set up the Nim development environment and project structure** Install Nim and Nimble, then create a project with a modular architecture where each audit target is a separate module implementing a common `Auditor` interface with a `scan()` method returning `seq[Finding]`. Define shared types for `Finding` (path, category, severity, description) and `AuditReport`. Configure static linking with `--passL:-static` for a zero-dependency binary. Set up cross-compilation targets for x86_64 and aarch64 Linux. The single-binary, no-dependency deployment model is why Nim appeals to security practitioners.

2. **Build the browser credential store auditor** Implement detection of credential databases in Firefox and Chromium browsers. Locate Firefox profile directories via `profiles.ini` and check for `logins.json` and `cookies.sqlite`. Find Chromium `Login Data` and `Cookies` SQLite databases. Report the number of stored entries, last modification time, and file permissions for each database found. Flag databases with world-readable or group-readable permissions as critical findings. The audit focuses on storage hygiene and access control posture.

3. **Implement SSH key and configuration auditing** Scan `~/.ssh/` for private keys (RSA, Ed25519, ECDSA, and non-standard filenames), configuration files, `known_hosts`, and `authorized_keys`. Inspect private key file headers to determine if they are passphrase-protected (encrypted PEM headers vs unencrypted). Flag unprotected private keys as high severity. Check file permissions against SSH best practices (private keys should be 600, the `.ssh` directory should be 700). Parse `~/.ssh/config` to enumerate configured hosts and identify entries using password authentication or disabled host key checking.

4. **Build the cloud provider configuration auditor** Scan standard locations for cloud provider configurations: AWS (`~/.aws/credentials`, `~/.aws/config`), GCP (`~/.config/gcloud/`), Azure (`~/.azure/`), and Kubernetes (`~/.kube/config`). For each discovered file, check permissions, parse the configuration to count the number of configured profiles or contexts, and identify whether credentials appear to be long-lived static keys versus short-lived session tokens. Flag any cloud credential file with permissions broader than owner-only. Report whether MFA or SSO configurations are present.

5. **Implement secrets-in-history detection** Read shell history files (`.bash_history`, `.zsh_history`, `.fish_history`) and apply pattern matching to identify commands that may have included inline secrets: environment variable exports containing words like KEY, SECRET, TOKEN, or PASSWORD, database connection strings with embedded credentials, and HTTP requests with authorization headers. Report the file, approximate line region, and a redacted preview for each match. Also scan for `.env` files in the home directory tree and report their locations, sizes, and permissions.

6. **Build the risk scoring and report generator** Assign each finding a severity score based on credential type sensitivity, access protection level, and exposure scope. Aggregate findings into a structured report with sections per category, an executive summary with an overall security posture rating (A through F), and specific remediation steps for each finding type (how to add SSH key passphrases, fix file permissions, migrate to credential managers, enable MFA). Output the report in JSON for tooling integration and as a formatted ANSI terminal display for human review.

7. **Add operational safety and output handling** Implement a `--dry-run` mode that lists which paths would be examined without reading content. Add `--scope` flags to limit auditing to specific categories. Build output encryption using AES-256-GCM with a passphrase-derived key so the audit report itself does not become a security liability. Implement an access log that records every filesystem path examined during the scan. Add `--exclude` patterns for paths that should be skipped. These features make the tool suitable for use during authorized professional assessments.

8. **Create a test environment and document usage** Build a Docker-based test environment that populates a container with mock credential files in all scanned locations: sample SSH keys (both protected and unprotected), dummy cloud configuration files, browser database stubs, and planted history entries. Run the auditor inside the container and verify it identifies all planted findings with correct severity ratings. Write documentation covering the tool's purpose, legal requirements for credential auditing, integration with penetration testing methodologies, and a comparison of findings against CIS Benchmark recommendations.

## Key Concepts to Learn
- Linux credential storage locations across browsers, SSH, cloud tools, and shells
- File permission models and their security implications on Linux
- Nim programming language fundamentals and static compilation
- Why Nim is adopted in the offensive security community
- Credential hygiene assessment methodology
- Risk scoring frameworks for security findings
- CIS Benchmark alignment for credential storage
- Ethical and legal requirements for security assessment tools

## Deliverables
- Statically-linked Nim binary with modular auditing architecture
- Five audit modules: browser, SSH/GPG, cloud providers, shell history, environment
- Risk scoring engine with severity categorization and remediation guidance
- Encrypted report output in JSON and formatted terminal display
- Docker-based test environment with comprehensive mock credentials
- Access logging for all filesystem operations during scans
- Documentation covering authorized usage, legal requirements, and CIS alignment
