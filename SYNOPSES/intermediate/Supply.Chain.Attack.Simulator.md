# Supply Chain Attack Simulator

## Overview
Build an educational supply chain attack demonstration in Python that illustrates the dependency confusion attack vector by creating a fake package, a vulnerable application that installs it, and a monitoring system that captures the exfiltration attempt. This project teaches one of the most impactful modern attack vectors — the same technique that earned Alex Birsan $130,000+ in bug bounties from Apple, Microsoft, and PayPal in 2021. You will understand how package managers resolve dependencies, why internal package names are dangerous, and how to defend against these attacks with namespace reservation, hash pinning, and scoped registries. Nothing is published to any real registry.

## Step-by-Step Instructions
1. **Set up the local PyPI server and project structure** Install and configure `pypiserver` as a local private package registry running on localhost. Create three separate project directories: the demonstration package, the target FastAPI application, and the monitoring server that captures exfiltration attempts. Configure `uv` to resolve packages from your local registry first (simulating a company's internal registry), then fall back to the real PyPI. This local-only setup ensures nothing is ever published to a real registry while accurately simulating the attack vector.

2. **Build the demonstration package** Create a Python package with a name that mimics an internal corporate library (e.g., `internal-auth-utils`). In its `setup.py`, add a post-install hook that executes during installation. The hook should collect non-sensitive system metadata: hostname, username, Python version, installed packages, and the current working directory. Instead of sending data to the internet, send it to your local monitoring server via HTTP POST to localhost. Use a high version number (99.0.0) to win version resolution over any legitimate internal package. Publish this package to your local pypiserver.

3. **Create the target FastAPI application** Build a small FastAPI application with a `pyproject.toml` that lists `internal-auth-utils` as a dependency. Add a `.env` file with fake database credentials and API keys for demonstration purposes. When you run `uv sync`, the demonstration package should install from the local registry because it has a higher version number than any internal version, and its post-install hook should fire automatically. Document exactly what happens at each step of the dependency resolution process to make the mechanics clear.

4. **Build the monitoring dashboard** Create a simple FastAPI server that listens for the POST requests from the demonstration package. Display received data in a formatted dashboard: which metadata was collected, from which host, at what time, and how. Store all captured data in a SQLite database for later analysis. Add a timeline view that shows the sequence of events from package installation to data collection. This makes the impact of dependency confusion viscerally clear.

5. **Implement detection and alerting mechanisms** Build three detection approaches: a pre-install hook that checks package hashes against a known-good lockfile and alerts on mismatches, a network monitor using `scapy` that flags unexpected outbound HTTP connections during package installation, and a filesystem monitor using `watchdog` that detects when install scripts access sensitive directories. Each detection method should produce clear alerts explaining what was detected and why it is suspicious.

6. **Create the defense implementation module** Build working implementations of every major defense: lockfile pinning with hash verification (demonstrate how `uv lock` prevents the attack), namespace reservation on PyPI (show the registration process), scoped registry configuration (route internal package names to the private registry only), package signing verification, and a policy-as-code tool that scans `pyproject.toml` files for packages that match internal naming conventions but resolve to public registries. Each defense should be testable against the attack scenario.

7. **Build the interactive demonstration runner** Create a CLI tool that orchestrates the entire demonstration end-to-end: starts the local PyPI server, publishes the demonstration package, installs the target application, captures the metadata collection, then runs each detection mechanism and shows what caught the attack. Include a `--narrated` mode that pauses between steps and prints explanations of what is happening and why. This makes the tool usable for live demonstrations and training sessions.

8. **Write the comprehensive analysis and documentation** Generate an automated report comparing the attack vector against each defense mechanism in a matrix format: which defenses would have prevented the attack at which stage. Include a section on real-world incidents (event-stream, ua-parser-js, colors.js) with analysis of how they relate to the demonstrated techniques. Add a section on responsible disclosure practices and the ethical boundaries of supply chain security research.

## Key Concepts to Learn
- Package manager dependency resolution algorithms and version precedence
- Dependency confusion and typosquatting attack vectors
- Post-install hook execution and its security implications
- Lockfile pinning, hash verification, and reproducible builds
- Network and filesystem monitoring for anomaly detection
- Supply chain security frameworks (SLSA, SSDF)
- Responsible disclosure and ethical boundaries of security research
- Real-world supply chain incidents and their root causes

## Deliverables
- Local PyPI server configuration with demonstration package
- Target FastAPI application demonstrating dependency confusion
- Monitoring dashboard with timeline visualization
- Three detection mechanisms (hash checking, network monitoring, filesystem monitoring)
- Five defense implementations with testable configurations
- Interactive CLI demonstration runner with narrated mode
- Analysis report comparing attack surface against defense matrix
