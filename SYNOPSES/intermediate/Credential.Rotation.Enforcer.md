# Credential Rotation Enforcer

## Overview
Build a credential lifecycle management platform in Python that tracks, monitors, and enforces rotation policies across all types of secrets in your infrastructure: API keys, database passwords, TLS certificates, SSH keys, and OAuth tokens. This project teaches the operational security discipline of credential hygiene, which is one of the most impactful yet neglected areas of security engineering. You will build a system that answers the question every security team dreads: "When was this credential last rotated, and who has access to it?"

## Step-by-Step Instructions
1. **Set up the Python project and credential registry** Initialize a Python project using `uv` with FastAPI for the API layer and SQLAlchemy for the database (PostgreSQL). Design a credential registry schema that tracks: credential type, owning service, creation date, last rotation date, rotation policy (max age in days), rotation method (manual or automated), current status (active, stale, expired, compromised), and an audit trail of all changes. Build CRUD API endpoints for registering and managing credentials. Never store the actual secret values — only metadata, hashes for verification, and rotation timestamps.

2. **Build the policy engine** Create a flexible policy engine that defines rotation requirements per credential type: API keys must rotate every 90 days, database passwords every 60 days, TLS certificates 30 days before expiry, SSH keys every 180 days, and OAuth client secrets every 120 days. Policies should be configurable via YAML files. Implement a policy evaluator that runs on a schedule (using APScheduler) and flags any credential that violates its rotation policy. Support policy exceptions with documented justification and expiry dates so teams can request temporary extensions.

3. **Implement automated rotation for AWS IAM keys** Build an auto-rotation module for AWS IAM access keys using `boto3`. The rotation process should: create a new access key for the IAM user, update the credential in the consuming service (via a configurable webhook or direct API call), verify the new key works by making a test API call, deactivate the old key, wait a configurable grace period, then delete the old key. Implement a rollback mechanism that reactivates the old key if verification fails. Log every step with timestamps for the audit trail. This module serves as the template for other auto-rotation implementations.

4. **Add auto-rotation for PostgreSQL passwords** Build a rotation module that connects to PostgreSQL as a superuser, generates a cryptographically strong new password, executes `ALTER ROLE ... PASSWORD ...`, updates the consuming application's configuration (via environment variable injection, Kubernetes secret update, or webhook callback), and verifies the new password works. Handle the tricky case where active database connections using the old password must be allowed to finish gracefully. Implement connection testing that waits for the application to start using the new credential before marking rotation complete.

5. **Build TLS certificate monitoring and renewal** Implement a certificate monitor that scans configured endpoints, parses the X.509 certificate, extracts the expiration date, and calculates days until expiry. Integrate with Let's Encrypt via the ACME protocol (using a library like `acme`) to automatically renew certificates when they are within the policy window. For non-Let's Encrypt certificates, generate CSRs and notify administrators. Track the full certificate chain, including intermediate certificates, and alert if any certificate in the chain is approaching expiry.

6. **Create the alerting and notification system** Build a multi-channel alerting system that sends notifications via webhook (Slack, Discord, Teams), email (via SMTP), and PagerDuty integration for critical alerts. Implement escalation levels: warning (credential approaching rotation deadline), critical (credential past deadline), and emergency (credential potentially compromised). Include snooze functionality so alerts can be temporarily silenced with a justification. Build alert deduplication to prevent notification fatigue — batch related alerts into a single daily digest except for emergency-level items.

7. **Build the compliance reporting dashboard** Create a FastAPI-served web dashboard (or JSON API for frontend integration) that provides: an overview of all credentials with their rotation status (color-coded), a compliance scorecard showing percentage of credentials meeting policy, a timeline view of upcoming rotations for the next 30/60/90 days, historical audit trails for any credential, and exportable reports in PDF and CSV format. Implement compliance report templates for SOC 2, ISO 27001, and PCI-DSS that map your rotation data to specific control requirements.

8. **Add discovery scanning and integration testing** Build a credential discovery module that scans infrastructure for unregistered credentials: AWS IAM keys not in the registry, PostgreSQL roles with passwords, TLS certificates on running services, and SSH authorized keys on hosts. Flag any discovered credential that is not tracked in the registry as "unmanaged" and alert the team. Write integration tests using Docker Compose that spin up PostgreSQL, a mock AWS endpoint (LocalStack), and the full application, then test the complete rotation lifecycle: register, monitor, auto-rotate, verify, and report.

## Key Concepts to Learn
- Credential lifecycle management and rotation best practices
- AWS IAM key rotation with zero-downtime strategies
- PostgreSQL credential management and connection handling
- X.509 certificate chain validation and ACME protocol
- Compliance frameworks (SOC 2, ISO 27001, PCI-DSS) credential requirements
- Alerting design: escalation levels, deduplication, and notification fatigue
- Audit trail design for security operations
- Infrastructure scanning and credential discovery

## Deliverables
- FastAPI application with credential registry and policy engine
- Auto-rotation modules for AWS IAM keys, PostgreSQL passwords, and TLS certificates
- Multi-channel alerting system with escalation and deduplication
- Compliance reporting dashboard with SOC 2 and PCI-DSS templates
- Credential discovery scanner for unmanaged secrets
- Docker Compose integration test environment with full lifecycle testing
- YAML-based policy configuration with exception management
