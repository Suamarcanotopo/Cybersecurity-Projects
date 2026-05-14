# SBOM Generator

## Overview
Build a Software Bill of Materials generator in Go that scans project directories, identifies dependencies from multiple ecosystems, resolves transitive dependency trees, and produces SBOM documents in both SPDX and CycloneDX formats. The tool cross-references discovered packages against CVE databases (NVD, OSV) to generate vulnerability reports alongside the SBOM. This project is directly relevant to US Executive Order 14028 on improving the nation's cybersecurity, which mandates SBOM production for all software sold to the federal government, making this a marketable real-world skill.

## Step-by-Step Instructions
1. **Set up the Go project and parser framework** Create a Go module with a plugin-style architecture where each package ecosystem has its own parser implementing a common `DependencyParser` interface with `Detect(dir string) bool` and `Parse(dir string) ([]Package, error)` methods. Define shared types: `Package` (name, version, ecosystem, license, checksums), `DependencyTree` (package with resolved transitive dependencies), and `Vulnerability` (CVE ID, severity, affected versions, fix version). Build a CLI using `cobra` with subcommands for scanning, generating SBOMs, and checking vulnerabilities. The plugin architecture makes it easy to add new ecosystem support.

2. **Build dependency parsers for major ecosystems** Implement parsers for five ecosystems: Python (`requirements.txt`, `pyproject.toml`, `Pipfile.lock`, `uv.lock`), Go (`go.mod`, `go.sum`), Node.js (`package.json`, `package-lock.json`, `pnpm-lock.yaml`), Rust (`Cargo.toml`, `Cargo.lock`), and Java (`pom.xml`, `build.gradle`). Each parser should extract direct dependencies with version constraints from manifest files and exact resolved versions from lockfiles when available. Handle version constraint syntax for each ecosystem (semver ranges, tilde, caret, wildcards). Prioritize lockfile data over manifest data since lockfiles contain the actual resolved versions.

3. **Implement transitive dependency resolution** For each ecosystem, resolve the full transitive dependency tree. For ecosystems with lockfiles (Go, Node, Rust), parse the lockfile which already contains the complete resolution. For ecosystems without lockfiles, query the package registry API to resolve transitive dependencies: PyPI JSON API for Python, npm registry for Node, crates.io for Rust. Build a dependency graph data structure that tracks direct vs transitive relationships, depth level, and whether multiple versions of the same package exist (dependency conflicts). Implement cycle detection to handle circular dependencies gracefully.

4. **Add license detection and package metadata enrichment** For each discovered package, determine its license by checking: the lockfile (some include license data), the package registry API (most registries return license information), and local source files (scan for LICENSE, COPYING, and SPDX headers in source). Map license strings to SPDX license identifiers using the SPDX license list. Enrich package metadata with: download URL, package homepage, maintainer information, and content checksums (SHA-256). Flag packages with no detectable license, packages with copyleft licenses in proprietary projects, and packages with known problematic licenses.

5. **Generate SPDX format SBOMs** Implement SPDX 2.3 document generation in both JSON and tag-value formats. Map your internal data structures to SPDX concepts: each package becomes an `SPDXPackage` with SPDXID, name, version, download location, checksums, license, and supplier. Represent dependency relationships using SPDX `Relationship` elements (DEPENDS_ON, BUILD_TOOL_OF, DEV_DEPENDENCY_OF). Include document-level metadata: creator tool identification, creation timestamp, document namespace, and data license (CC0-1.0). Validate generated documents against the SPDX JSON schema to ensure compliance.

6. **Generate CycloneDX format SBOMs** Implement CycloneDX 1.5 document generation in JSON format. Map packages to CycloneDX `component` objects with type (library, framework, application), name, version, purl (Package URL), licenses, and hashes. Represent the dependency tree using CycloneDX `dependencies` objects that link each component to its direct dependencies. Include `metadata` with tool identification, component being described, and manufacture date. Validate generated documents against the CycloneDX JSON schema. Implement both the flat component list and the hierarchical dependency tree representation.

7. **Build the vulnerability scanner** Integrate with two vulnerability databases: the NVD (National Vulnerability Database) via its REST API and OSV (Open Source Vulnerabilities) via its API. For each package in the SBOM, query both databases for known CVEs affecting the detected version. Match using CPE identifiers for NVD and Package URLs for OSV. For each vulnerability found, record the CVE ID, CVSS score, severity rating, affected version range, fixed version (if available), and a brief description. Generate a vulnerability report sorted by severity that can be included as a VEX (Vulnerability Exploitability Exchange) document alongside the SBOM.

8. **Add CI/CD integration and policy enforcement** Build a `--check` mode that evaluates the SBOM against configurable policies and returns a non-zero exit code if violations are found. Policies include: no dependencies with critical CVEs, no dependencies with unknown licenses, no dependencies older than a configurable age threshold, and maximum allowed dependency tree depth. Implement GitHub Actions and GitLab CI configuration templates that run the SBOM generator on every PR and block merging if policy violations are detected. Write integration tests that scan known project fixtures and verify the generated SBOMs contain the expected packages, relationships, and vulnerability matches.

## Key Concepts to Learn
- Software Bill of Materials purpose and regulatory requirements (EO 14028)
- SPDX and CycloneDX specification structures and differences
- Package manager dependency resolution across ecosystems
- Transitive dependency trees and supply chain depth
- License compliance detection and SPDX identifiers
- CVE databases (NVD, OSV) and vulnerability matching via CPE and PURL
- VEX documents for vulnerability communication
- CI/CD integration for automated supply chain security

## Deliverables
- Go CLI tool with pluggable ecosystem parsers
- Five ecosystem parsers: Python, Go, Node.js, Rust, Java
- Transitive dependency resolution with graph visualization
- SPDX 2.3 and CycloneDX 1.5 document generation with schema validation
- Vulnerability scanner integrating NVD and OSV databases
- Policy enforcement engine with configurable rules
- CI/CD templates for GitHub Actions and GitLab CI
- Integration tests with known project fixtures
