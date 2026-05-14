# GraphQL Security Tester

## Overview
Build an automated security testing tool in Python for GraphQL APIs that discovers and exploits common GraphQL-specific vulnerabilities: introspection exposure, query depth and complexity attacks, authorization bypass, field suggestion abuse, batching attacks, and mutation injection. You will also build an intentionally vulnerable GraphQL server to test against, creating a complete offensive and defensive learning environment. GraphQL's flexible query language introduces unique attack surfaces that traditional web application scanners miss entirely, making specialized tooling essential for modern API security.

## Step-by-Step Instructions
1. **Set up the project and build the vulnerable GraphQL server** Initialize a Python project with `uv` and create an intentionally vulnerable GraphQL API using `strawberry-graphql` with FastAPI. Design a schema for a multi-tenant application with users, organizations, projects, and secrets. Deliberately introduce vulnerabilities: leave introspection enabled in production mode, implement no query depth limits, use sequential integer IDs (enabling enumeration), implement authorization checks at the resolver level but inconsistently (some resolvers skip checks), and expose sensitive fields that should be filtered based on user role. Seed the database with test data across multiple tenants so authorization bypass is demonstrable.

2. **Build the introspection analysis module** Implement a module that sends the standard GraphQL introspection query (`__schema`) and parses the complete schema: all types, fields, arguments, mutations, subscriptions, and their relationships. Build a schema analyzer that automatically identifies security-relevant findings: fields named password, secret, token, or key; mutations that modify user roles or permissions; types that expose internal identifiers; deprecated fields that might have weaker security controls; and input types that accept file uploads. Generate a visual schema map in DOT format (for Graphviz) and a structured JSON report of all findings.

3. **Implement query depth and complexity attacks** Build a module that generates deeply nested queries to test for denial-of-service vulnerabilities. Start with the schema analysis to find circular relationships (e.g., User has Projects, Project has Members who are Users), then automatically generate queries that exploit these cycles to create exponential query complexity. Implement configurable depth (10, 20, 50, 100 levels) and breadth (number of fields per level). Measure server response time and memory usage to determine when the server becomes degraded. Also implement field duplication attacks (requesting the same expensive field thousands of times via aliases) and fragment spread attacks.

4. **Build the authorization bypass testing module** Implement systematic authorization testing: for each query and mutation in the schema, send requests with no authentication, with a low-privilege user token, and with a token for a different tenant. Compare responses to detect authorization failures — if a low-privilege user can access a field that returns data for another tenant, that is an IDOR (Insecure Direct Object Reference). Build an automated IDOR scanner that iterates through sequential and UUID-based identifiers on every field that accepts an ID argument. Test for horizontal privilege escalation (accessing another user's data at the same privilege level) and vertical escalation (accessing admin-only fields as a regular user).

5. **Implement batching and mutation injection attacks** Build a module that exploits GraphQL batching (sending arrays of queries in a single request) to amplify attacks: send 1000 login attempts in a single HTTP request to bypass rate limiting, batch multiple mutations to test for transaction isolation issues, and use batched queries to enumerate valid identifiers. Implement mutation injection testing: for mutations that accept complex input types, test each field for injection vulnerabilities by inserting SQL injection payloads, NoSQL injection operators, and command injection strings. Track which payloads trigger error messages that reveal internal implementation details.

6. **Build the field suggestion and information disclosure module** Implement a module that exploits GraphQL's helpful error messages. When you query a non-existent field, many GraphQL servers suggest similar valid field names in the error response. Use this to enumerate the schema even when introspection is disabled: start with common field names (id, name, email, password, role, admin), extract suggestions from error messages, and recursively probe suggested fields to reconstruct the schema. Also test for verbose error messages that leak stack traces, database query details, or internal service URLs. Build a schema reconstruction engine that maps the discovered fields into a partial schema.

7. **Create the subscription abuse testing module** Implement testing for GraphQL subscription vulnerabilities: connect to the WebSocket endpoint and subscribe to events across tenant boundaries (can User A receive events for User B's data?), subscribe to an excessive number of channels simultaneously (resource exhaustion), and test whether subscription authentication is validated on connection and on each event delivery. Also test for subscription injection — whether subscription filter arguments are vulnerable to the same injection attacks as queries. Measure WebSocket connection limits and server resource consumption under subscription load.

8. **Build the reporting engine and CI integration** Create a comprehensive reporting engine that aggregates findings from all modules into a unified security report. Categorize findings by severity (critical, high, medium, low, informational) using a scoring system aligned with OWASP API Security Top 10. Generate reports in JSON (for automation), HTML (for stakeholders with interactive severity filtering), and SARIF (for GitHub code scanning integration). Build a CI/CD mode that runs a configurable subset of tests and returns a non-zero exit code if findings above a severity threshold are detected. Include a `--baseline` mode that compares current results against a previous scan and only reports new findings.

## Key Concepts to Learn
- GraphQL schema structure and introspection mechanics
- Query depth and complexity as denial-of-service vectors
- Authorization models in GraphQL: field-level, type-level, and resolver-level
- IDOR vulnerabilities in GraphQL through ID enumeration
- Batching attacks for rate limit bypass and brute force amplification
- Schema reconstruction when introspection is disabled
- WebSocket security for GraphQL subscriptions
- OWASP API Security Top 10 mapping for GraphQL-specific issues

## Deliverables
- Python security testing CLI for GraphQL APIs
- Intentionally vulnerable GraphQL server with multi-tenant data
- Introspection analyzer with visual schema mapping
- Query depth/complexity attack generator with DoS measurement
- Authorization bypass scanner with IDOR detection
- Batching and mutation injection testing modules
- Schema reconstruction engine via field suggestion exploitation
- Unified reporting in JSON, HTML, and SARIF formats with CI integration
