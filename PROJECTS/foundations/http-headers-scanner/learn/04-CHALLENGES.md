# Extension Challenges

You have read the code and you understand what it does. Time to make it yours.

These challenges are ordered roughly by difficulty. The early ones are 30-minute changes. The later ones are weekend projects that meaningfully change how the scanner works. None of them have "the right answer" hidden in this folder. Try them, get them wrong, get them right, learn something.

If you get stuck, the source of truth is always the code. Re-read `evaluate_header()` and `scan()` and `_render_report()`. The whole scanner fits on a screen.

## Warm-up challenges

### 1. Add a seventh header to check

**Goal:** Extend `RULES` with one more security header. Pick one of:

- **`Cross-Origin-Opener-Policy`** (COOP): prevents the page from being interacted with by other origins via window.opener. Recommended value: `same-origin`.
- **`Cross-Origin-Embedder-Policy`** (COEP): controls which cross-origin resources can be loaded. Recommended value: `require-corp`.
- **`Cross-Origin-Resource-Policy`** (CORP): controls who can embed this resource. Recommended value: `same-origin`.

**Why it is useful.** These three headers together (COOP, COEP, CORP) are the modern way to isolate a page from cross-origin attacks like Spectre. Real high-security sites set all three.

**Hints.**
- Add a `HeaderRule(...)` to `RULES`. Pick a severity. Decide whether you need a `must_match` pattern (a plain word like `"same-origin"` works as a substring check; use a richer regex if "the value has to be exactly one of N options" matters).
- The score totals will change. Your existing tests that assert exact scores may break. Either update those tests or write them in terms of percentages.
- Test it against a real site. `https://web.dev` is a good one to check.

**Done when.** `just test` passes, `just run -- https://web.dev` shows your new header in the table.

### 2. Add a `--json` flag for machine-readable output

**Goal.** Make the scanner emit a JSON blob when the user passes `--json`, instead of the colored table.

**Why useful.** CI systems and dashboards need structured output. A grep-friendly table is fine for humans, JSON is fine for everyone else.

**Hints.**
- Add a `--json` boolean flag to `_build_argument_parser()` using `action="store_true"`.
- In `main()`, after `scan()` returns, branch on `args.json`. If True, use the standard library's `json` module to dump a dict with the report fields. If False, call the existing `_render_report()`.
- `HeaderFinding` is not directly JSON-serializable because it contains a nested `HeaderRule`. You can flatten it manually, or use `dataclasses.asdict()` which converts a frozen dataclass tree into nested dicts.

**Done when.** `just run -- https://example.com --json | jq '.score'` prints just the score number.

### 3. Add a `--verbose` flag that prints raw response headers

**Goal.** Optional flag that, when set, prints every header the server returned (including non-security ones) above the table.

**Why useful.** When debugging "why does the scanner say my HSTS is weak," you want to see the raw value the server sent.

**Hints.**
- Add the flag the same way as `--json`.
- The `scan()` function only stores findings, not the raw response. You will need to thread the raw headers through `ScanReport` (add a new field) or have `scan()` return a tuple.
- Print the raw headers in `_render_report` when a verbose flag is passed. The renderer signature will need updating.

**Done when.** `just run -- https://example.com --verbose` shows all server headers above the findings table.

## Intermediate challenges

### 4. Scan multiple URLs in one run

**Goal.** Allow the user to pass several URLs and get a report per URL. Bonus: a summary table at the end.

**Why useful.** When auditing a company's sites, you do not want to run the scanner once per URL. Run it once over the whole list.

**Hints.**
- Change the `url` argparse argument to accept `nargs="+"` (one or more). `args.url` becomes a list of strings.
- Loop over the URLs in `main()`. Call `scan()` for each, render each report, collect them.
- For the summary, add a small final table with one row per URL: URL, score, grade.
- The exit code becomes interesting. Probably the worst grade across all URLs.

**Edge cases.**
- One URL fails (network error) but others succeed. Do you still exit with code 2?
- Two URLs return the same final URL (after redirects). Dedupe or show both?

### 5. Add an `--allow-warnings` style threshold flag

**Goal.** Let the user say "I am ok with grade C, only exit non-zero if grade D or below."

**Why useful.** CI integrations. Different teams have different acceptance bars.

**Hints.**
- Add `--min-grade` taking a value from `{"A", "B", "C", "D", "F"}`. Default to `"C"` (the current behaviour roughly).
- In `main()`, compare `report.grade` to the threshold and pick exit code accordingly.
- Grades have a natural order. You can compare them with a small helper that maps each to an integer.

**Done when.** `just run -- https://example.com --min-grade C` exits 0 if the site got C or better, exits 1 otherwise.

### 6. Cache results to disk

**Goal.** When the user re-scans the same URL within the last hour, return the cached result instead of hitting the network.

**Why useful.** When you are iterating on the renderer or scoring, you do not want to spam a real site every test run.

**Hints.**
- Store cached reports in `~/.cache/http-headers-scanner/`.
- File name from a hash of the URL (`hashlib.sha256(url.encode()).hexdigest()`).
- Use `dataclasses.asdict(report)` to JSON-ify, `json.dump()` to write.
- Include a timestamp in the cached file. Skip the cache when it is older than an hour.
- Add a `--no-cache` flag to bypass.

**Tricky bit.** `HeaderFinding` contains a `HeaderRule`. When you load from cache, you need to rebuild those rules from the JSON. Or, simpler, only cache the bits you care about and rebuild the report shape from scratch.

### 7. Detect and warn about mixed HTTP/HTTPS

**Goal.** If the user passes an `http://` URL and the server redirects to `https://`, mention it prominently in the output.

**Why useful.** Many sites enforce HTTPS via redirect, but the redirect chain itself is unencrypted on the first hop and gets stripped by attackers (this is what HSTS protects against). Knowing whether a redirect happened is a useful signal.

**Hints.**
- After `scan()`, compare `report.url` (what the user typed) to `report.final_url` (where they ended up).
- If the user typed `http://...` and the final URL is `https://...`, print a one-line note: "Note: this URL was upgraded from HTTP to HTTPS via redirect. Without HSTS, the first request is vulnerable to interception."
- Better yet, deduct points if HSTS is missing AND the user came in via http.

## Advanced challenges

### 8. Make it async to scan many sites in parallel

**Goal.** Use `httpx.AsyncClient` plus `asyncio.gather` so that scanning 50 URLs takes about the time of one scan, not 50 scans.

**Why useful.** Real audits cover many hosts. Sequential scanning is the bottleneck.

**Hints.**
- Add an `async def scan_async(url, ...)` alongside `scan()`. Use `async with httpx.AsyncClient() as client:` and `client.get(...)`.
- In `main()`, build an `asyncio.gather()` over a list of `scan_async` calls.
- Concurrency limit: do not blast 5000 URLs at once. Use `asyncio.Semaphore(20)` to cap parallelism.
- The pure functions (`evaluate_header`, `score`, `grade`) do not change. That is the payoff of separating pure logic from I/O.

**Watch out for.** Some sites rate-limit aggressive scanning. The default User-Agent identifies us; respect any `Retry-After` headers if they come back.

### 9. Add a static analyser for the CSP value

**Goal.** Currently we only check that `Content-Security-Policy` is present. Build a sub-analyser that looks inside the CSP value and reports specific problems:

- Contains `'unsafe-inline'` in `script-src`? Major weakness, points off.
- Contains a wildcard origin (`*`) in `script-src`? Same.
- Missing `default-src`? Worth noting.

**Why useful.** A CSP that allows `'unsafe-inline'` is barely a CSP at all. Real scanners (Mozilla Observatory) do this analysis. Yours can too.

**Hints.**
- Add a new dataclass `CSPAnalysis` with fields like `has_unsafe_inline: bool`, `wildcard_origins: list[str]`, etc.
- Add a `parse_csp(value: str) -> CSPAnalysis` pure function. CSP grammar: directives are semicolon-separated; each directive is `name source1 source2 ...`.
- Make the CSP rule's `weak` status take into account the analysis result. The base `evaluate_header` will need an escape hatch for rules that have a custom validator.

**Tricky bit.** CSP is genuinely complex. The official spec is at `w3.org/TR/CSP3`. Start by parsing only `script-src`; ignore the rest.

### 10. Build a continuous monitor

**Goal.** Run the scanner against a list of URLs every 24 hours and alert when a site's grade drops.

**Why useful.** Configuration drifts. A site that had grade A six months ago can drop to B because someone disabled HSTS to debug something and forgot to put it back. You want to know.

**Hints.**
- Need persistent storage. Easiest start: a SQLite database with columns `(url, run_at, score, grade)`. Standard library has `sqlite3` so no new dependency.
- A separate script reads a URL list (one URL per line, in a file), runs the scanner, writes results.
- Compare today's grade to the most recent previous grade per URL. If today is worse, emit an alert (print to stdout, send an email, push a Slack message, your choice).
- A `cron` entry or a systemd timer fires the script once a day.

**Watch out for.** Networks are flaky. A timeout one day is not necessarily a grade drop. You probably want a "two failures in a row" rule before alerting.

### 11. Browser-based comparison: scan the same URL with three different User-Agents

**Goal.** Sites sometimes serve different headers to bots versus real browsers. Add a `--compare-uas` mode that scans the same URL with the default scanner UA, with a Chrome UA, and with a Googlebot UA, then shows a side-by-side comparison of the headers.

**Why useful.** A site might serve strict CSP to real users but loose CSP to bots, or vice versa. Knowing this is real evidence of a misconfiguration.

**Hints.**
- The `scan()` function already takes a `user_agent` argument. Run it three times with three different values.
- A real Chrome UA looks like: `Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36`.
- Googlebot's UA is `Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)`.
- The render layer needs a "three-column comparison" mode. A rich Table with columns "Default", "Chrome", "Googlebot" and one row per header.

## Expert challenge

### 12. Make it a service with a REST API

**Goal.** Wrap the scanner in a small HTTP server. POST a URL, get back a JSON report.

**Why useful.** Other services in a security pipeline can call yours. Plus, it is the natural way to make the scanner accessible from a frontend.

**Estimated time.** A weekend if you have not used FastAPI before, a few hours if you have.

**Prerequisites.** Some exposure to web frameworks would help. The intermediate `siem-dashboard` project in this repo is a deeper example of building one.

**Architecture sketch.**

```
┌─────────────────────────────────────────────────────┐
│ FastAPI app                                          │
│                                                      │
│  POST /scan { "url": "..." }                         │
│       └──▶ async scan_async(url) ────▶ ScanReport    │
│       ◀── { "url": ..., "grade": ..., findings: ... }│
│                                                      │
│  GET /healthz                                        │
│       └──▶ {"ok": true}                              │
└─────────────────────────────────────────────────────┘
```

**Steps.**

1. **Add fastapi and uvicorn to dependencies.** `uv add fastapi uvicorn[standard]`.
2. **Create a new file `server.py`** that imports `scan_async` from your async-ified scanner.
3. **Define a Pydantic model** for the request body (`class ScanRequest(BaseModel): url: HttpUrl`).
4. **Define a response model** that mirrors `ScanReport` for serialisation. `HttpUrl` validates URLs at the API boundary.
5. **Add the route.** `@app.post("/scan", response_model=ScanResponse)` then `async def scan_endpoint(req: ScanRequest)`.
6. **Add a healthz endpoint** so external monitors can confirm the service is alive.
7. **Add rate limiting.** Otherwise people will use your service to scan strangers. The advanced `api-rate-limiter` project in this repo is a good reference.

**Production checklist.**
- [ ] Validation: reject internal IPs (`127.0.0.1`, `10.0.0.0/8`, etc.) to prevent SSRF.
- [ ] Timeouts: every scan has a hard cap so a slow target cannot tie up workers.
- [ ] Logging: every request is logged with `url`, `grade`, `duration_ms`.
- [ ] CORS: decide which origins can call your API.
- [ ] Deploy: Dockerfile that runs uvicorn, env var for port.

**Stretch goal.** Build a tiny single-page frontend (vanilla HTML + JS, no framework needed) that lets a user paste a URL and shows the report. Now you have a real product.

## Other directions

A few smaller ideas if none of the above grab you:

- **Color-blind mode.** Replace the green/yellow/red colors with green/yellow/red plus distinct shapes (✓, ⚠, ✗) so the table is readable for color-blind users.
- **HAR file import.** Instead of scanning a live URL, read headers from a `.har` file (HTTP Archive, what browsers export from dev tools). Lets you scan responses you captured earlier.
- **Show diff against a known good baseline.** Save a "reference report" for a URL. On next scan, show only the changes ("HSTS got weaker," "X-Frame-Options went missing").
- **Add a `--strict` mode** that lowers the bar: deduct points even for minor issues (e.g. `max-age` less than six months, missing `includeSubDomains`).

## What to do when stuck

The strategy that works every single time:

1. **Reduce.** Strip the problem down. Comment out everything except the smallest piece that still misbehaves.
2. **Print.** When `evaluate_header` does not return what you expected, print the inputs and the outputs. Do not guess what they look like. Look.
3. **Read the test.** If a test is failing, the test is telling you exactly what it expected. Read the assertion. Read the inputs. Compare to the actual output.
4. **Diff against known good.** Use `git diff` to see what changed since the tests last passed. The bug is in your changes 99% of the time.

If after all that you still need help, the GitHub Discussions tab on the repository is the right place. Bring:
- What you tried.
- What you expected.
- What actually happened (the full error if any).
- The smallest reproducer that shows the problem.

"It does not work" is not enough information to help with. The above four bullets are.

## When you finish a challenge

Make it yours. If you build something interesting, write it up. Push it to your own fork. Open a pull request back to the main repo if your improvement is generally useful. The best way to lock in what you learned is to teach someone else.
