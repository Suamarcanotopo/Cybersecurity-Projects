# Token Abuse Playground

## Overview
Build an intentionally vulnerable fullstack application using FastAPI and React that contains 15+ distinct token-based authentication and session management vulnerabilities, each with a guided exploit walkthrough and corresponding fix. This project teaches the mechanics of token-based authentication failures that appear consistently in OWASP Top 10 findings and real-world bug bounty reports. You will implement JWTs, session cookies, API keys, and OAuth flows, then systematically break each one to understand why specific implementation choices lead to exploitable vulnerabilities.

## Step-by-Step Instructions
1. **Set up the fullstack project with a vulnerable authentication system** Initialize a FastAPI backend with a React frontend. The backend should implement three authentication mechanisms simultaneously: JWT bearer tokens, session cookies, and API keys. Use PostgreSQL for user storage and Redis for session management. Deliberately configure each mechanism with specific weaknesses: accept the JWT `none` algorithm, use a symmetric secret that is also used elsewhere, set overly long session expiry, and store API keys in plain text. Build a basic user registration and login flow so you have working authentication to attack.

2. **Implement JWT-specific vulnerabilities** Create five JWT attack scenarios: the `none` algorithm bypass (accept tokens with `alg: none` and no signature), RS256-to-HS256 key confusion (verify RS256 tokens using the public key as an HMAC secret), weak signing secrets vulnerable to brute force (use a dictionary word), missing expiration validation (accept tokens without `exp` claim), and JWT injection via `kid` header parameter manipulation (SQL injection through the key ID lookup). Each vulnerability should be isolated to its own API endpoint group so students can focus on one at a time.

3. **Build session and cookie vulnerabilities** Implement five session-based attack scenarios: session fixation (accept session IDs provided by the client before authentication), weak session ID generation (use sequential integers or predictable timestamps), missing cookie security flags (no HttpOnly, no Secure, no SameSite), session token in URL parameters (leaking via Referer header), and session persistence after password change (old sessions remain valid). Create a session inspector page in the React frontend that visualizes the current session state and cookie attributes.

4. **Add API key and OAuth vulnerabilities** Build five more vulnerability scenarios: API key leakage in client-side JavaScript (embed keys in React bundle), CSRF on the token refresh endpoint (no CSRF protection on POST /refresh), OAuth open redirect manipulation (insufficient redirect_uri validation), token scope escalation (modify the scope claim in a token and the server accepts it), and bearer token leakage via verbose error messages (include the token in 500 error responses). For the OAuth flow, implement a minimal OAuth2 authorization server within the project.

5. **Create the guided exploit walkthrough system** Build a challenge-and-response system in the React frontend. Each vulnerability gets a dedicated page with: a description of the vulnerability class, the specific endpoint(s) to attack, hints that can be revealed progressively, an input field to submit the exploit (e.g., a forged token), and server-side validation that confirms successful exploitation. Use a progress tracker stored in localStorage so students can see which vulnerabilities they have completed.

6. **Build the fix verification system** For each vulnerability, implement a "patched" version of the same endpoint behind a feature flag. Create a comparison view in the React UI that shows the vulnerable code alongside the fixed code with explanations of what changed and why. Build automated tests that verify each fix actually prevents the exploit: the test should succeed against the vulnerable endpoint and fail against the patched one. This teaches both offense and defense simultaneously.

7. **Implement the monitoring and detection dashboard** Build a real-time dashboard in React that shows authentication events as they happen: login attempts, token validations, session creations, and detected attack patterns. Use WebSocket connections from FastAPI to push events. Implement basic detection rules that flag suspicious activity: multiple failed JWT signature validations, session fixation attempts, and unusual token refresh patterns. This teaches students what these attacks look like from the defender's perspective.

8. **Add a scoring system and wrap up with documentation** Implement a scoring system that awards points based on vulnerability severity (CVSS-aligned) and tracks time to exploit. Create a leaderboard page. Write comprehensive setup documentation including a Docker Compose configuration that launches the entire stack with one command. Include a reference guide mapping each vulnerability to its CWE number, OWASP category, and real-world CVEs where this exact bug was found in production software.

## Key Concepts to Learn
- JWT structure, signing algorithms, and common implementation mistakes
- Session management lifecycle and cookie security attributes
- OAuth 2.0 authorization flows and redirect validation
- CSRF attack mechanics on authentication endpoints
- The difference between authentication, authorization, and session management
- How token-based attacks appear in monitoring and detection systems
- OWASP Top 10 authentication failure patterns
- Defense-in-depth for token-based authentication

## Deliverables
- FastAPI backend with 15+ intentional token vulnerabilities
- React frontend with guided exploit walkthrough and hints
- Fix verification system with side-by-side vulnerable and patched code
- Real-time attack monitoring dashboard via WebSocket
- Docker Compose configuration for one-command deployment
- Automated test suite verifying both exploits and fixes
- Reference guide mapping vulnerabilities to CWE and OWASP categories
