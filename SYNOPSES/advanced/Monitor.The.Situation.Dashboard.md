# "Monitor the Situation" Dashboard

## Overview
Build a comprehensive cybersecurity situational awareness platform in Python with a React frontend that aggregates real-time threat intelligence from multiple sources into a single operational dashboard. The platform features a global threat map with IP geolocation from threat feeds, a CVE velocity tracker showing newly published vulnerabilities with CVSS scoring, a threat actor leaderboard tracking APT groups mapped to MITRE ATT&CK, an exploit availability monitor tracking weaponization timelines, social media threat intelligence aggregation, and infrastructure health correlation. Inspired by the "monitor the situation" meme but built as a genuinely useful security operations tool pulling from NVD, MITRE, GreyNoise, AbuseIPDB, Shodan, and social feeds.

## Step-by-Step Instructions

1. **Design the data aggregation architecture** with a Python backend using FastAPI that orchestrates data collection from multiple threat intelligence APIs on different schedules. Build an async task system (Celery or APScheduler) that polls each data source at appropriate intervals (CVEs every 15 minutes, threat feeds hourly, social media every 5 minutes), normalizes data into a unified schema, and stores it in PostgreSQL with TimescaleDB for time-series analytics. Design the API layer to serve real-time and historical data to the React frontend via REST and WebSocket.

2. **Build the global threat map** by ingesting data from threat intelligence feeds (GreyNoise, AbuseIPDB, AlienVault OTX) and geolocating attacking IPs using MaxMind GeoIP2. Render an interactive world map in React using a mapping library showing real-time attack origins, destination concentrations, attack type classification (scanning, brute force, exploitation), and animated connection lines between source and target regions. Aggregate by country, ASN, and threat category.

3. **Implement the CVE velocity tracker** pulling from the NVD API (National Vulnerability Database) with real-time monitoring for new CVE publications. Display CVEs with CVSS 3.1 scoring, severity badges, affected technologies, and trending indicators. Build analytics showing publication velocity (CVEs per day/week), severity distribution trends, most targeted technology stacks, and highlight critical CVEs (CVSS 9.0+) with special alerts. Include EPSS (Exploit Prediction Scoring System) data to predict which CVEs will be exploited.

4. **Create the threat actor leaderboard** using MITRE ATT&CK data and open threat intelligence to track known APT groups. Display each group's attributed campaigns, targeted sectors and geographies, TTPs (Tactics, Techniques, and Procedures) mapped to ATT&CK, and activity recency. Build a ranking system based on recent campaign frequency, target diversity, and technique sophistication. Link to detailed group profiles with IOCs.

5. **Build the exploit availability monitor** that tracks the lifecycle from CVE publication to weaponized exploit. Monitor sources including GitHub (PoC repositories), Exploit-DB, Metasploit module additions, and nuclei template releases. Calculate and display time-to-exploit metrics: average days from CVE to first PoC, from PoC to weaponized exploit, and from exploit to mass scanning. Alert when critical CVEs get weaponized.

6. **Implement social media threat intelligence** by aggregating security researcher posts from Twitter/X API (or Mastodon) and RSS feeds from security blogs. Use keyword filtering and NLP to surface posts about new vulnerabilities, active exploitation, zero-days, and incident reports. Often these posts break news hours before official feeds. Display in a real-time feed with source credibility scoring.

7. **Build the React dashboard frontend** with a SOC-style layout designed for large displays: the global threat map as the centerpiece, CVE velocity charts and critical alerts along the top, threat actor activity and exploit availability panels on the sides, and the social media feed as a scrolling ticker. Implement dark mode (essential for SOC environments), configurable refresh intervals, customizable panel layouts, and full-screen presentation mode.

8. **Add infrastructure correlation and alerting** where users can input their own technology stack (languages, frameworks, cloud providers, specific product versions) and the dashboard correlates global threats against their exposure. Highlight when a new CVE affects their stack, when an exploit drops for a vulnerability in their infrastructure, or when threat actors targeting their sector become active. Send alerts via Slack, Discord, PagerDuty, or email.

## Key Concepts to Learn
- Threat intelligence aggregation and normalization
- CVE lifecycle and CVSS scoring
- MITRE ATT&CK framework and threat actor tracking
- Exploit prediction and weaponization tracking
- IP geolocation and attack visualization
- Real-time data streaming with WebSockets
- Time-series analytics and trend detection
- SOC dashboard design and operational workflows

## Deliverables
- FastAPI backend with async data collection
- Global threat map with real-time IP geolocation
- CVE velocity tracker with EPSS scoring
- Threat actor leaderboard with ATT&CK mapping
- Exploit availability monitor with weaponization timelines
- Social media threat intelligence feed
- React SOC-style dashboard with configurable panels
- Infrastructure correlation and personalized alerting
