# LLM Prompt Injection Firewall

## Overview
Build a middleware layer in Python that sits between users and LLM APIs to detect and block prompt injection attacks, jailbreak attempts, and data extraction techniques before they reach the model. The firewall uses pattern matching, input sanitization, and heuristic analysis to classify threat levels in user inputs, maintaining a test suite of known injection techniques and a scoring system for risk assessment. This is the most modern cybersecurity project possible—as LLMs become infrastructure, securing them is the new application security.

## Step-by-Step Instructions

1. **Study prompt injection attack taxonomy** by researching the major categories: direct injection (overriding system prompts with "ignore previous instructions"), indirect injection (hidden instructions in retrieved documents), jailbreaking (DAN, roleplay-based bypasses), data extraction (getting the model to reveal system prompts or training data), and encoding-based attacks (base64, ROT13, leetspeak to bypass filters). Build a comprehensive test suite of 50+ known techniques.

2. **Implement the HTTP proxy middleware** that intercepts API calls to LLM providers (OpenAI, Anthropic, etc.), inspects the user message content before forwarding, applies detection rules, and either allows, modifies, or blocks the request based on threat assessment. Return informative error messages when requests are blocked, explaining what was detected without revealing detection specifics.

3. **Build pattern-based detection** using regular expressions and string matching for known injection patterns: "ignore previous instructions," "you are now," "pretend you are," system prompt extraction attempts, encoding indicators (base64 strings, hex sequences), and role-switching language. Weight patterns by specificity—exact known jailbreak phrases score higher than generic suspicious language.

4. **Implement heuristic analysis** beyond simple pattern matching: measure input entropy (encoded payloads have unusual character distributions), detect language switching (injection attempts often switch between natural language and instruction language), identify nested instruction formats (XML tags, markdown formatting used to confuse prompt boundaries), and flag unusual input length distributions.

5. **Add input sanitization capabilities** that can optionally modify rather than block suspicious inputs: strip potential injection delimiters, escape special formatting characters, truncate excessively long inputs, and normalize Unicode to prevent homoglyph-based bypasses. Allow configuration of whether to block, sanitize, or log-only for each threat category.

6. **Build the scoring and decision engine** that combines all detection signals into a composite threat score (0-100) with configurable thresholds for allow, warn, and block actions. Log all decisions with full details for security review. Implement learning mode that logs everything but blocks nothing, useful for tuning thresholds before enforcement.

7. **Create an admin dashboard** (simple Flask/FastAPI web UI) showing real-time request flow, blocked requests with reasons, threat score distribution, most common attack patterns seen, and false positive review queue where admins can mark blocked requests as legitimate to improve detection.

8. **Write documentation** covering the prompt injection threat landscape, OWASP Top 10 for LLMs, defense-in-depth strategies (this firewall is one layer, not the only defense), comparison to commercial solutions (Rebuff, LLM Guard), and guidance on tuning detection thresholds for different risk tolerances.

## Key Concepts to Learn
- Prompt injection attack techniques and taxonomy
- LLM security and OWASP Top 10 for LLMs
- HTTP proxy and middleware design
- Pattern matching and heuristic analysis
- Input sanitization and normalization
- Risk scoring and decision engines
- Security logging and monitoring

## Deliverables
- HTTP proxy middleware for LLM API interception
- Pattern-based injection detection engine
- Heuristic analysis (entropy, language switching, nesting)
- Input sanitization with configurable modes
- Composite threat scoring with tunable thresholds
- Admin dashboard for monitoring and tuning
- Test suite of 50+ known injection techniques
