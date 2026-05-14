# Core Concepts

This file explains the security ideas the scanner is built on. By the end you should know what HTTP is, what a header is, why the six headers we check exist, and what kind of attack each one stops.

Read this file before the code. The code is short; the concepts behind it are what take the time.

## 1. What HTTP actually is

When you type `github.com` into your browser, something has to go fetch the page. That "something" speaks a protocol called **HTTP** (HyperText Transfer Protocol). HTTPS is the same protocol with encryption wrapped around it.

The basic shape of an HTTP conversation is:

```
                       HTTP request
   ┌─────────────┐ ───────────────────────▶ ┌─────────────┐
   │             │                          │             │
   │   Browser   │                          │   Server    │
   │   (you)     │                          │  (github)   │
   │             │ ◀─────────────────────── │             │
   └─────────────┘       HTTP response      └─────────────┘
```

You (the browser) send a **request**. The server sends back a **response**. The request says "I would like the page at /home/index.html, please." The response says "Here is that page. Also, here is some information about the page."

Both the request and the response are just **text**, with a specific layout.

### What a real response looks like

If you stripped away the encryption and watched the bytes coming back from `https://example.com`, you would see something like this:

```
HTTP/2 200
content-type: text/html; charset=UTF-8
content-length: 1256
strict-transport-security: max-age=31536000
x-frame-options: DENY
cache-control: max-age=600
date: Tue, 13 May 2026 12:00:00 GMT

<!doctype html>
<html>
  <head><title>Example Domain</title></head>
  <body>...</body>
</html>
```

Three parts to notice:

1. **The status line.** `HTTP/2 200` means "HTTP version 2, status code 200." 200 means "OK, here is your page." 404 would mean "I do not have that page." 500 would mean "I broke trying to make that page."
2. **The headers.** Everything between the status line and the blank line. Each header is one line, in the format `name: value`. There can be dozens of them.
3. **The body.** Everything after the blank line. The actual HTML, image, JSON, or whatever else the server is sending you.

The **headers** are what this scanner cares about. Some headers are about caching, content type, cookies, and so on. We ignore those. A specific six headers exist for security, and that is what we grade on.

### Why headers are case insensitive

You will sometimes see `Strict-Transport-Security` and sometimes `strict-transport-security`. **They mean the same thing.** RFC 7230, the official spec for HTTP, says header names are case insensitive. Different servers and proxies use different casing. The scanner has to handle all of them, which is why we lowercase both sides before comparing.

## 2. What a security header actually is

A security header is just a regular HTTP header with a name the browser has been programmed to recognise as a security instruction. There is nothing magic about them. The server sends `Strict-Transport-Security: max-age=31536000` and the browser thinks "ah, the website is telling me to remember to only use HTTPS to talk to it for the next 31,536,000 seconds (one year)."

If the server forgets to send the header, the browser falls back to its default behaviour, which is usually "do whatever, no special protections." That default is what attackers count on.

So security headers are basically a **promise** the website makes to your browser. "Trust me, I never serve content over plain HTTP. If you ever see me on plain HTTP, somebody is lying to you, ignore them."

## 3. The six headers we grade

The scanner checks six headers. Each one stops a specific class of attack. We will go through them one by one.

### 3.1 Strict-Transport-Security (HSTS): severity HIGH

**What it tells the browser**

"For the next N seconds, only ever talk to me over HTTPS. Never plain HTTP. If somebody hands you a link to `http://my-site.com`, upgrade it to `https://` before you make the request."

**The attack it stops: SSL stripping**

Imagine you are at a coffee shop and you type `github.com` into your browser (no `https://` prefix). Your browser, by default, tries `http://github.com` first. GitHub's server then says "actually, please use HTTPS" and redirects you. The browser follows the redirect, switches to HTTPS, and now everything is encrypted.

In the gap between "you sent a plain HTTP request" and "the redirect came back," an attacker on the same wifi (running a laptop with `bettercap` or `sslstrip`) can intercept everything. They sit in the middle:

```
   ┌────────┐    plain HTTP    ┌──────────┐    HTTPS    ┌────────┐
   │  You   │ ───────────────▶ │ Attacker │ ──────────▶ │ GitHub │
   └────────┘                  │  (MITM)  │             └────────┘
                               └──────────┘
```

The attacker keeps talking to GitHub over real HTTPS, but talks to you over plain HTTP, and rewrites every `https://` link in the page back to `http://` so you never escape. You think the site looks normal. The attacker reads your password.

**How HSTS stops it.** The first time you visit GitHub successfully over HTTPS, your browser remembers the `Strict-Transport-Security` header. Next time, even if you type `http://github.com`, the browser refuses to send a plain HTTP request at all. It upgrades to `https://` locally, before any packet leaves your machine. The attacker's "intercept the plain HTTP step" trick stops working.

**What the value looks like**

```
Strict-Transport-Security: max-age=31536000; includeSubDomains
```

- `max-age=31536000`: remember this rule for 31,536,000 seconds (one year).
- `includeSubDomains`: apply the rule to `api.github.com`, `docs.github.com`, everything ending in `github.com`.

**Why the scanner requires a positive `max-age`.** A server could send `Strict-Transport-Security:` with no value, or `Strict-Transport-Security: max-age=0`. Both are useless. `max-age=0` actively **disables** HSTS (it tells the browser to forget any previous HSTS rule for this site). So presence alone is not enough. The scanner reports `weak` whenever the value does not match the pattern `max-age = <positive integer>` — which catches both the empty case and the deliberately-zero case.

**Real example.** Moxie Marlinspike's sslstrip demo at Black Hat 2009 made this attack famous. Every major bank moved to enforce HTTPS-only after that talk. As of 2026 almost every serious site sends HSTS. Sites that do not are usually old internal systems.

### 3.2 Content-Security-Policy (CSP): severity HIGH

**What it tells the browser**

"Here is the exact list of places I am willing to load scripts, styles, images, fonts, frames, and other resources from. If you see something on the page asking you to load from anywhere else, refuse."

**The attack it stops: cross-site scripting (XSS)**

XSS is when an attacker manages to inject their own JavaScript into a page that other users will see. Classic example:

```
Comment box on the site allows: I love this product!
Attacker types:                 <script>steal_cookie()</script>
Site displays it verbatim.
Now every user who loads the comment runs the attacker's JS in their session.
```

That JS runs with the full trust of the website, so it can read cookies, read the page's session token, send requests to the API as the user, and so on. This is bug class number 7 in the OWASP Top 10 for years.

**How CSP stops it.** The website tells the browser "scripts may only come from `https://my-site.com` or from `https://cdn.my-site.com`." When the browser sees `<script>steal_cookie()</script>` embedded inline in the HTML, it goes "that script does not come from one of the allowed origins, I refuse to run it." The injected XSS just becomes inert text.

**What the value looks like**

```
Content-Security-Policy: default-src 'self'; script-src 'self' https://cdn.example.com
```

- `default-src 'self'`: for anything not specifically listed below, only allow content from this exact site.
- `script-src 'self' https://cdn.example.com`: JavaScript can come from this site or from cdn.example.com.

A real CSP is much longer because real sites pull in fonts, analytics, embeds, etc. A good CSP **never** contains `'unsafe-inline'` for scripts (which would allow the inline `<script>` tags an XSS attack relies on).

**Real example.** GitHub's CSP is one of the longest in the industry. After their 2018 GitHub-Pages XSS, they tightened it significantly. You can see it yourself: load github.com in your browser, open dev tools, look at the response headers.

**Why we only check for presence.** Parsing CSP properly is hard. Mozilla Observatory does a much deeper analysis (checks for `unsafe-inline`, wildcard origins, missing `default-src`, etc.). Our scanner only checks the header is present. That is the right call for a foundations project: graduate to Observatory once you want the deeper analysis.

### 3.3 X-Content-Type-Options: severity MEDIUM

**What it tells the browser**

"When I send you a file, I am telling you its type with the `Content-Type` header. Believe me. Do not look at the bytes and decide for yourself."

**The attack it stops: MIME sniffing**

Older versions of Internet Explorer had a "helpful" feature: if a server said a file was `text/plain` but the contents looked like HTML, IE would treat it as HTML and render it. The intent was to be forgiving toward misconfigured servers. The effect was a massive security hole.

Attack: a website lets users upload a profile picture. Attacker uploads a file named `cute_cat.gif` whose first bytes look like a valid GIF, but contains `<script>steal_everything()</script>` further in. Server stores it. Server later serves it back to other users with `Content-Type: image/gif`. IE looks at the bytes, sees the `<script>` tag, says "this is actually HTML" and runs the script. Now the attacker has XSS via image upload.

**How the header stops it.** `X-Content-Type-Options: nosniff` tells the browser "do not second-guess my Content-Type." If I say `image/gif`, you treat it as an image, full stop. The script tag never runs.

**What the value looks like**

```
X-Content-Type-Options: nosniff
```

That is literally the only allowed value. The header is the most boring of the six because there is one correct setting and that is it.

**Why the scanner requires `nosniff`.** Some misconfigured servers send `X-Content-Type-Options: off` or other garbage. The header has to literally contain the string `nosniff` to be useful. If it does not, we report `weak`.

**Real example.** Most of the MIME sniffing vulnerabilities were in IE 6 through 9. Modern browsers default to nosniff behaviour for `script` and `style` resources regardless. The header still matters for older browsers and for non-script contexts.

### 3.4 X-Frame-Options: severity MEDIUM

**What it tells the browser**

"Do not let other websites put me inside an `<iframe>` on their pages."

**The attack it stops: clickjacking**

Imagine the attacker makes a webpage that says:

```
   ┌────────────────────────────────────────┐
   │  Win a free iPhone! Click here!        │
   │                                        │
   │   ┌──────────────────────────┐         │
   │   │ [INVISIBLE iframe with   │         │
   │   │  github.com loaded       │         │
   │   │  inside it, positioned   │         │
   │   │  so the "Delete repo"    │         │
   │   │  button sits exactly     │         │
   │   │  over the "Click here"   │         │
   │   │  button]                 │         │
   │   └──────────────────────────┘         │
   └────────────────────────────────────────┘
```

You are logged into GitHub in another tab. You see the "free iPhone" page on attacker's site. You click. The click does not land on the visible "Click here" button. It passes through the transparent iframe and lands on GitHub's "Delete repo" button. Your session cookie travels with the click. GitHub thinks you wanted to delete the repo, so it deletes it.

This is **clickjacking**. The CSS to set up the overlay is trivial. The only thing stopping it from working on every login session everywhere is the victim site refusing to be framed.

**How the header stops it.** `X-Frame-Options: DENY` tells the browser "if you see me being loaded inside an iframe on any other page, refuse to render me." The clickjacking iframe stays blank. Click goes nowhere harmful.

**What the value looks like**

```
X-Frame-Options: DENY            # never allow framing, ever
X-Frame-Options: SAMEORIGIN      # only allow framing by pages on the same domain
```

`X-Frame-Options` is the old way. The modern way is the `frame-ancestors` directive inside `Content-Security-Policy`. Most real sites send both for browser-compatibility reasons. The scanner only checks `X-Frame-Options` to keep things simple.

**Real example.** Adobe's Flash settings page in 2008 was clickjackable. Twitter's "Follow this user" button got clickjacked into "Re-tweet anything" attacks in 2009. Facebook had a clickjacking worm in 2010 that spread via "likes" on rigged pages. The pattern is the same every time.

### 3.5 Referrer-Policy: severity LOW

**What it tells the browser**

"When you leave my page to go to another site, do not tell that other site exactly which page you came from."

**The leak it stops: referer leakage**

Browsers, by default, send a `Referer` header with every outgoing request that says "the user got here from this URL." Yes, the spelling is `Referer` with one R. That was a typo in the original HTTP spec from 1996 and we are stuck with it forever. Hilarious.

Why this matters. Suppose your website has URLs like:

```
https://my-site.com/password-reset?token=abc123xyz
```

A user lands on that page, clicks an external link (say, to a YouTube help video). Their browser tells YouTube "this user came from `https://my-site.com/password-reset?token=abc123xyz`." YouTube now has the user's password reset token in their access logs. Anyone with log access at YouTube has it too.

This has happened in real life many times. The pattern: secret tokens in URLs leak via the Referer header to every third-party resource the page loads.

**How the header stops it.** `Referrer-Policy: strict-origin-when-cross-origin` is a sensible default. It says "when the user goes to another site, only tell that site my origin (`https://my-site.com`), never the full URL with query params. Hide the path and query string."

**What the value looks like**

```
Referrer-Policy: strict-origin-when-cross-origin
Referrer-Policy: no-referrer                       # most paranoid
Referrer-Policy: same-origin                       # safe for outbound links
```

**Why severity is LOW.** Referer leakage is real and bad, but it depends on the site putting secrets in URLs in the first place, which is a separate mistake. The header is a useful belt-and-suspenders defence, but missing it is not a guaranteed loss.

### 3.6 Permissions-Policy: severity LOW

**What it tells the browser**

"This page does not use the camera. Do not let any code on this page, including embedded third-party scripts, ask the user for camera access."

You can do this for camera, microphone, geolocation, USB devices, payment APIs, accelerometer, and a long list of other browser features.

**The attack it stops: feature abuse through compromised third parties**

Imagine your site embeds an analytics script from a third party. That third party gets hacked. The attacker pushes a malicious update to the analytics script. Now every page on your site that includes the script is running attacker code with access to whatever the browser allows. If the attacker writes `navigator.mediaDevices.getUserMedia({ audio: true })`, the user gets a "this site wants to use your microphone" prompt. Many users will click yes because they trust your site.

**How the header stops it.** `Permissions-Policy: camera=(), microphone=()` tells the browser "no code on this page may request camera or microphone, regardless of source. Do not even show the prompt." The attacker's script gets a denied response and moves on.

**What the value looks like**

```
Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=()
```

The empty parentheses mean "no origins are allowed to use this feature." You can also explicitly allowlist origins, but for most sites the right answer for most features is "nobody."

**Why severity is LOW.** This only matters if (a) your site embeds third-party code, AND (b) that third-party gets compromised, AND (c) the third party would otherwise try to use these features. It is genuinely defence in depth, but it is several steps removed from the immediate attack surface.

## 4. The scoring rubric

So we have six headers. Each one has a severity (high, medium, low) that maps to a point value:

```
high   = 30 points each
medium = 15 points each
low    = 5 points each
```

The current rules table has 2 highs, 2 mediums, 2 lows. Total achievable: `2*30 + 2*15 + 2*5 = 90` points. Wait, that does not add up to 100? Correct. The math:

```
60 (two highs)   + 30 (two mediums) + 10 (two lows) = 100 points
```

I miscounted. Let me redo it: high=30, two highs is 60. Medium=15, two mediums is 30. Low=5, two lows is 10. Total: 60+30+10 = **100**.

For each header, the scanner produces a finding:

- `ok` → earn the full point value for that rule
- `weak` → earn half points (the header is present but the value is broken)
- `missing` → earn zero

Then:

```
score = round( (earned points / total points) * 100 )
```

The score becomes a grade by a standard letter-grade cutoff:

```
score >= 90 → A
score >= 80 → B
score >= 70 → C
score >= 60 → D
otherwise   → F
```

This mirrors how Mozilla Observatory and securityheaders.com work. They use different exact point values and check more headers, but the shape is the same: weighted findings, percentage score, letter grade.

## 5. What this scanner does NOT do

Being clear about scope is important. This is a foundations project. It is **not**:

- **A crawler.** It scans exactly the URL you give it. One request. It does not follow links inside the page and grade every subpage.
- **A CSP analyser.** We only check that `Content-Security-Policy` exists. We do not look inside the value for `unsafe-inline`, wildcard sources, missing `default-src`, etc.
- **A vulnerability scanner.** It does not try to find SQL injection, XSS, open redirects, or any actual exploitable flaw. It only reports on missing defensive configuration.
- **An authority.** Real sites sometimes intentionally drop certain headers because they break a feature they need. A missing header is a signal worth investigating, not an automatic verdict.

When you want a fuller picture, graduate to:
- **Mozilla Observatory** (`observatory.mozilla.org`): does everything we do plus deep CSP analysis, cookie checks, TLS configuration grading.
- **securityheaders.com**: similar idea, simpler UI.
- **`nmap` with the http-security-headers script**: for command line nerds.

## 6. Industry references

If you want to look these up yourself in official docs:

- **MDN** (developer.mozilla.org) has authoritative articles on each header. Search for the header name plus "MDN."
- **OWASP Secure Headers Project** (owasp.org/www-project-secure-headers) has the canonical list and recommended values.
- **RFC 6797** is the spec for HSTS. RFC 7034 is the spec for X-Frame-Options. Reading specs is a useful skill even when the spec is boring.
- **CWE-693** "Protection Mechanism Failure" is the common-weakness ID for missing or misconfigured defensive headers.

## 7. Quick self check

You should be able to answer these before moving on to architecture:

1. What is the difference between an HTTP request and an HTTP response?
2. Where do headers sit in a response (relative to the status line and the body)?
3. Which header would have prevented SSL stripping at the coffee shop?
4. Which header would have prevented the clickjacking-style "delete repo" attack?
5. Why does the scanner report `weak` instead of `ok` when `X-Content-Type-Options` is present but its value is not literally `nosniff`?
6. What kind of attack does CSP defend against, and why does it not parse the CSP value deeply?
7. What is the grade for a site with score 75? What about 60? What about 59?

If any of these feel fuzzy, re-read the relevant section. The implementation in the next two files will make much more sense once these are solid.

## Next

Move on to **[02-ARCHITECTURE.md](./02-ARCHITECTURE.md)** for how the scanner is organised in code, or jump straight to **[03-IMPLEMENTATION.md](./03-IMPLEMENTATION.md)** for the line-by-line walkthrough.
