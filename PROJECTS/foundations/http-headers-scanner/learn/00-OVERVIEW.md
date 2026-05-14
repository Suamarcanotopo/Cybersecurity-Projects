# http-headers-scanner

A small command line tool that visits a website, asks for the "rules" that the website tells your browser to follow, and grades the website A through F based on how good those rules are.

This is the middle project in the **foundations** tier. The first foundations project (`hash-identifier`) was pure logic with no network. The third one (`password-manager`) is a full small application. This project sits between them: one trip across the internet, then some grading math.

## Why anyone built this

Every time you visit a website, your browser and the website's server have a short conversation. The browser asks "give me the page" and the server sends back two things:

1. The page itself (the HTML, images, scripts).
2. A short list of **rules** about how to treat that page.

That second list is what we care about here. It is called the **response headers**. Some of those headers are security related. They tell your browser things like:

- "From now on, only talk to me over HTTPS. Never plain HTTP."
- "Do not let any other website put me inside an `<iframe>`."
- "If you receive a file from me and you are not sure what type it is, do not guess. Treat it strictly."
- "Block scripts unless they come from this exact list of trusted places."

If a website forgets to send these headers, real attacks become easier. A few examples that actually happened to real companies:

- **Clickjacking.** Without `X-Frame-Options`, an attacker can load a victim's website inside a hidden iframe on a malicious page, trick you into clicking what looks like a button on the malicious page, but your click really lands on the victim's site. Used against Twitter, Facebook, and Adobe Flash settings in the 2008 to 2012 era.
- **SSL stripping.** Without `Strict-Transport-Security`, an attacker on the same coffee shop wifi can downgrade your first visit to plain HTTP, sit in the middle, and read or change everything you send. Moxie Marlinspike demoed this at Black Hat 2009 and it is still effective on any site that forgets HSTS.
- **MIME sniffing.** Without `X-Content-Type-Options: nosniff`, a browser may treat an uploaded file as something it is not (an "image" that the browser decides looks like HTML and runs as a script). Real attack against legacy IE that worked because the browser tried to be helpful.

This scanner does NOT fix any of those. It just tells you whether a website is missing the headers that would have prevented them. That is the first useful job in security: knowing what is wrong before you can try to fix it.

## What you will learn by building it

This is not a tutorial that teaches you Python from the absolute first line. It assumes you can install something on your computer and run a command in the terminal. Everything past that, we will walk through.

After working through this project you should understand:

**Security concepts**
- What HTTP headers are and why some of them matter for security
- The specific attacks each major security header prevents (clickjacking, MIME sniffing, mixed content, XSS, referer leakage)
- How a "grading rubric" lets you turn many small checks into one final score, which is what real scanners like Mozilla Observatory and securityheaders.com do

**Python concepts**
- How to make an HTTP request from code with `httpx`
- How `dataclasses` give you small "shapes" of data without writing constructors by hand
- How `Literal` type hints pin a value to a small fixed set of strings so typos get caught early
- How to split "code that does I/O" (talks to the network) from "code that is pure math" so you can test the math without touching the network
- How `pytest` runs tests, what a fixture is, and how `respx` lets you fake HTTP responses

**Command line tooling**
- How `argparse` parses flags like `--timeout 5` into a tidy object
- How exit codes (the number a program returns when it finishes) can communicate success or failure to other programs and to CI systems
- How `rich` draws colored tables and panels in the terminal

## What it looks like when you run it

```bash
$ just run -- https://github.com
```

You will see something like this (colors are real in the terminal):

```
                  Headers for https://github.com/ (HTTP 200)
┌─────────────────────────────┬─────────┬──────────┬─────────────────────────┐
│ header                      │ status  │ severity │ note                    │
├─────────────────────────────┼─────────┼──────────┼─────────────────────────┤
│ Strict-Transport-Security   │ ok      │ high     │ Present and contains... │
│ Content-Security-Policy     │ ok      │ high     │ Present                 │
│ X-Content-Type-Options      │ ok      │ medium   │ Present and contains... │
│ X-Frame-Options             │ ok      │ medium   │ Present                 │
│ Referrer-Policy             │ ok      │ low      │ Present                 │
│ Permissions-Policy          │ missing │ low      │ Header ... is not set   │
└─────────────────────────────┴─────────┴──────────┴─────────────────────────┘
╭─ Result ───────────────────╮
│ Grade: A                   │
│ Score: 95 / 100            │
╰────────────────────────────╯

Recommendations:
  • Permissions-Policy — Add: Permissions-Policy: camera=(), microphone=(), geolocation=()
```

The big takeaways:
- A green table row means "this header is set and useful."
- A yellow row means "this header is set but the value is wrong" (for example, `Strict-Transport-Security` was sent but with `max-age=0`, which actively disables itself).
- A red row means "this header is missing entirely."
- The grade panel summarises everything into one letter so you can tell at a glance whether a site has its basics in order.

## Who this is for

You can be absolutely brand new to Python and to security. You should already know:

- How to open a terminal on your computer.
- How to clone a git repository (or download a folder of files).
- How to read text and not panic when something does not work on the first try.

You do NOT need to know in advance:

- What HTTP is. We will explain it.
- What a dataclass is. We will explain it.
- What pytest is, what mocking is, what argparse is. All explained.

## Prerequisites in real terms

**Software you need installed on your computer.** All three are free.

- **Python 3.13 or newer.** Python is the programming language this is written in. Version 3.13 added some of the syntax we use. If you have an older Python (3.10, 3.11, 3.12) you will get errors. Check with `python3 --version`.
- **A terminal.** Mac and Linux have one built in (Terminal.app or any of dozens on Linux). Windows users should install Windows Terminal from the Microsoft Store, or use the one inside VS Code.
- **A working internet connection.** The scanner makes one real HTTPS request to whatever URL you point it at.

The install script (`install.sh`) will set up everything else for you: `uv` (a Python package manager), `just` (a command runner), a virtual environment, and all the libraries this project uses.

## Quick start

From the project folder:

```bash
# One-shot install. Sets up Python tooling, installs dependencies.
./install.sh

# Scan a real site.
just run -- https://example.com

# Add a custom timeout if a site is slow to respond.
just run -- https://github.com --timeout 5

# Run the tests to confirm the code works on your machine.
just test
```

If `./install.sh` errors out with "permission denied," run `chmod +x install.sh` first to mark the file as executable, then try again.

## Project layout

The whole project is intentionally small. Two Python files plus tooling.

```
http-headers-scanner/
├── http_headers_scanner.py        the actual scanner: rules, scoring, CLI
├── test_http_headers_scanner.py   tests for the scanner
├── pyproject.toml                 project metadata + dependency list
├── uv.lock                        exact versions of every dependency
├── justfile                       shortcut commands (just test, just run, etc.)
├── install.sh                     one-shot installer
├── README.md                      a brief readme for the GitHub page
└── learn/                         this folder you are reading
    ├── 00-OVERVIEW.md             you are here
    ├── 01-CONCEPTS.md             what HTTP is, what each header does, real attacks
    ├── 02-ARCHITECTURE.md         how the code is organised and why
    ├── 03-IMPLEMENTATION.md       line by line walkthrough of the code
    └── 04-CHALLENGES.md           extension ideas to make it your own
```

Everything important lives in **one Python file** (`http_headers_scanner.py`). That is on purpose for a foundations project. One file you can hold in your head. Bigger projects (the password manager, anything in `intermediate/`) split into many files because they have to. This one does not have to.

## Common first-time issues

**`python3: command not found`**
You probably have Python installed but under a different name. Try `python --version`. If that says 3.13+, edit `install.sh` and replace `python3` with `python`. If neither works, install Python from python.org (or `brew install python@3.13` on Mac, `sudo apt install python3.13` on Debian/Ubuntu).

**`./install.sh: Permission denied`**
The file is not marked as executable. Run `chmod +x install.sh` and try again.

**`just: command not found` after install**
The install script puts `just` in `~/.local/bin`. That folder may not be on your PATH in a fresh terminal. Either restart your terminal or run `export PATH="$HOME/.local/bin:$PATH"`. To make it permanent, add that line to `~/.bashrc` or `~/.zshrc`.

**Network errors when scanning a real URL**
If you are behind a corporate firewall or VPN, some sites may refuse to respond, or they may block the scanner's default User-Agent. That is not a bug in the code, it is the world being annoying. Try a different URL like `https://example.com` first to confirm the basic plumbing works.

## Where to go next

1. **[01-CONCEPTS.md](./01-CONCEPTS.md)** explains HTTP from scratch, what each header actually does, and the real-world attacks they prevent. Read this before the code. The code makes much more sense once you understand what the headers are protecting against.
2. **[02-ARCHITECTURE.md](./02-ARCHITECTURE.md)** explains how the code is split into pieces and why. Useful when you want to extend the scanner without making a mess.
3. **[03-IMPLEMENTATION.md](./03-IMPLEMENTATION.md)** walks through the code line by line. This is the longest of the five files.
4. **[04-CHALLENGES.md](./04-CHALLENGES.md)** is for after you have read everything and want ideas for extending the project.

## Related projects in this repo

- `PROJECTS/foundations/hash-identifier/`: even smaller. Pure logic, no network. Good warmup if this one feels too big.
- `PROJECTS/foundations/password-manager/`: the next step up from this one. Multiple files, real cryptography.
- `PROJECTS/advanced/bug-bounty-platform/`: what a serious version of this idea looks like when you grow it into a whole product.
