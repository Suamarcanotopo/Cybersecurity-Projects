# Cloud Security Compliance Dashboard

## Overview
Build a multi-cloud security compliance platform in Go with a React dashboard that scans AWS, Azure, and GCP for misconfigurations, checks resources against CIS benchmarks, SOC2, HIPAA, and PCI-DSS frameworks, and presents results through executive dashboards with compliance scoring, trend tracking, and cost-security optimization. The platform includes automated remediation recommendations with Terraform snippets, continuous monitoring with drift detection, and reporting suitable for both technical teams and C-level executives. This project teaches enterprise cloud security assessment at scale and demonstrates the architecture behind commercial CSPM platforms like Prisma Cloud and Wiz.

## Step-by-Step Instructions

1. **Design the multi-cloud assessment architecture** with a plugin-based scanner system where each cloud provider has its own assessment module implementing a common interface. Build a Go service that orchestrates scans across providers, normalizes findings into a unified format, and stores results in PostgreSQL. Design the data model to support historical tracking, trend analysis, and multi-account/multi-project scanning.

2. **Implement AWS assessment using the AWS SDK for Go** scanning for misconfigurations across core services: S3 buckets (public access, encryption, logging), IAM policies (overly permissive roles, unused credentials, MFA enforcement), EC2 security groups (unrestricted inbound, unused rules), RDS instances (public accessibility, encryption, backup retention), CloudTrail (enabled, log validation, multi-region), VPC (flow logs, default security groups), and Lambda (excessive permissions, VPC configuration). Map each check to specific CIS benchmark controls.

3. **Build Azure and GCP assessment modules** following the same pattern: Azure checks for Storage Account exposure, RBAC role assignments, Network Security Groups, Key Vault policies, and Azure AD configurations. GCP checks for Cloud Storage IAM bindings, Compute Engine firewalls, Cloud SQL encryption, IAM custom roles, and Audit Log configuration. Implement provider-specific authentication handling and API rate limiting.

4. **Create the compliance framework mapping engine** that maps cloud configurations to multiple compliance frameworks simultaneously: CIS benchmarks (200+ controls per provider), SOC2 Trust Service Criteria, HIPAA Security Rule requirements, and PCI-DSS controls. Compute compliance scores as percentages per framework, per provider, and per resource category. Support multiple compliance profiles (strict for production, relaxed for development).

5. **Build cost-security optimization analysis** that correlates cloud billing data with security findings: identify resources that are both expensive AND insecure (high-cost EC2 instances with public security groups), find security improvements that also reduce cost (eliminating unused public IPs, right-sizing over-provisioned resources), and calculate the cost-of-risk for each finding.

6. **Implement the React dashboard** with executive views showing overall compliance posture across all clouds, drill-down by provider/region/service, trend charts showing compliance improvement or degradation over time, a geographic map of resources and their security status, and a risk-prioritized finding list with remediation effort estimates. Include role-based views for executives (high-level scores) and engineers (specific findings with fix commands).

7. **Add automated remediation recommendations** that generate actionable fixes for each finding: Terraform code snippets that remediate the misconfiguration, CLI commands for immediate manual fixes, and infrastructure-as-code templates for preventive controls. Implement an approval workflow where security teams review recommendations before execution, and track remediation status through to completion.

8. **Build continuous monitoring and drift detection** that re-scans on a configurable schedule (hourly, daily), detects configuration drift from the last known-good state, alerts on new findings via webhooks (Slack, PagerDuty), and generates compliance trend reports showing improvement velocity. Compare live state against Terraform state files to detect unauthorized manual changes.

## Key Concepts to Learn
- Multi-cloud security assessment architecture
- CIS benchmark framework implementation
- SOC2, HIPAA, PCI-DSS compliance requirements
- Cloud provider SDKs and API rate limiting
- Compliance scoring and trend analysis
- Cost-security optimization correlation
- Infrastructure-as-code remediation
- Continuous monitoring and drift detection

## Deliverables
- Multi-cloud scanner (AWS, Azure, GCP)
- CIS benchmark compliance checking (200+ controls)
- SOC2, HIPAA, PCI-DSS framework mapping
- Cost-security optimization analysis
- React executive dashboard with drill-downs
- Automated remediation with Terraform snippets
- Continuous monitoring with drift detection
- Webhook alerting and trend reporting
