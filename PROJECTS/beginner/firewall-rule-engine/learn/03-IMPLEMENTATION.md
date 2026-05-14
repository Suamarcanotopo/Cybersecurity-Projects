<!-- © AngelaMos | 2026 | 03-IMPLEMENTATION.md -->

# Code Walkthrough

This document walks through the actual source code file by file. Every function reference includes its location so you can open it and read alongside. The goal is to make the implementation legible, not to repeat the code verbatim. Open the files in your editor as you read.

---

## V Language Patterns Used

Quick reference of V patterns you will see throughout the codebase. If you already know Go or C, most of this will feel familiar. The main things that might surprise you are option types and flag enums.

**Module system.** Every file starts with `module name`. Imports use selective syntax: `import src.models { Rule, Ruleset, Finding }` pulls specific types into scope without requiring the `models.` prefix at every call site. The directory name is the module name. All files in a directory share the same module scope, which is how test files access private functions.

**Option types.** `?Type` means the value might be `none`. Two ways to unwrap:

- `if val := optional { ... }` where the `:=` inside `if` binds the unwrapped value only if it is not `none`
- `val := opt or { default }` for providing a fallback

The parser uses option types heavily for fields like `source ?NetworkAddr` and `in_iface ?string` in the `MatchCriteria` struct in `models.v`. A firewall rule might or might not specify a source address, and "not specified" is semantically different from any address value. The option type makes this distinction impossible to forget.

**Result types.** `!Type` means the function might return an error. Same unwrap patterns as option types. The `!` propagation operator lets callers bubble errors upward without writing error-handling boilerplate: `parse_network_addr(tokens[i])!` returns the error to the caller if parsing fails. Most parse functions return `!` because input can always be malformed.

**Flag enums.** The `@[flag]` attribute on an enum declaration makes it a bitfield instead of a single-value enum. Each variant occupies one bit position. The `ConnState` enum in `models.v` uses this so a single variable can hold any combination of connection states. The operations: `.has()` tests one flag, `.set()` turns one on, `.all()` checks if all flags in one value are present in another, `.is_empty()` checks if no flags are set, `.zero()` creates a value with no flags set.

**String interpolation.** `'text ${expression} more text'` with `${}` for any expression. V calls the `.str()` method automatically when you interpolate a type that has one, which is why every enum in models.v defines a `str()` method.

**Array methods.** `.map()`, `.filter()`, `.any()`, `.all()`, `.contains()` work like you would expect from functional languages. The implicit `it` variable refers to the current element. For example, in the `find_mergeable_ports` function in `optimizer.v`, `entries.map(it[0])` pulls the first element from each sub-array to extract rule indices.

**`in` operator.** Checks membership in arrays: `dp.start in high_traffic_ports` in the `suggest_reordering` function in `optimizer.v`. Also works on maps: `key !in tables_seen` in the `export_as_iptables` function in `generator.v`.

**`mut` for mutability.** Variables and parameters are immutable by default. Declare `mut i := 0` to allow mutation. Function parameters that the function modifies must also be declared `mut` in the signature, like the `parse_nft_table` function in `nftables.v` which takes `mut ruleset Ruleset`.

---

## CLI Entry Point (main.v)

`src/main.v`

The entry point is a subcommand dispatcher. The `main` function checks `os.args.len`, extracts the subcommand from `os.args[1]`, and dispatches via a `match` statement to one of: `cmd_load`, `cmd_analyze`, `cmd_optimize`, `cmd_harden`, `cmd_export`, `cmd_diff`, `cmd_version`, `cmd_help`. Unknown commands print an error and exit with `config.exit_usage_error`.

Each command function follows the same pattern: validate arguments, call `load_ruleset` to parse the input file, then call the appropriate module functions and display the results.

**`load_ruleset`**: The bridge between the CLI and the rest of the system. It reads the file, calls `parser.detect_format` to auto-detect iptables vs nftables, and dispatches to the correct parser:

```v
fn load_ruleset(path string) !models.Ruleset {
	if !os.exists(path) {
		return error('file not found: ${path}')
	}
	content := os.read_file(path) or { return error('cannot read file: ${path}') }
	fmt := parser.detect_format(content)!
	return match fmt {
		.iptables { parser.parse_iptables(content)! }
		.nftables { parser.parse_nftables(content)! }
	}
}
```

All three steps propagate errors with `!`, so a bad file path, unrecognized format, or parse failure each produce a clean error message.

**`cmd_harden`**: The most complex command because it accepts flags. It uses V's `flag` module to parse `--services` (comma-separated service names, defaults to `config.default_services`), `--iface` (network interface, defaults to `config.default_iface`), and `--format` (iptables or nftables). After parsing flags, it splits the service string on commas, trims whitespace, and calls `generator.generate_hardened`.

**`cmd_analyze`**: Loads the ruleset, prints a summary, then runs both conflict detection (`analyzer.analyze_conflicts`) and optimization suggestions (`analyzer.suggest_optimizations`). The results are printed as two separate sections with their own headers.

**`cmd_diff`**: Loads two rulesets from two different files and passes both to `display.print_diff`. Because `load_ruleset` auto-detects format, you can diff an iptables file against an nftables file. The comparison uses the canonical `Rule.str()` form which normalizes both formats to the same representation.

---

## Config Module (config.v)

`src/config/config.v`

This file is nothing but `pub const` declarations. No functions, no logic, no state. Everything the rest of the codebase needs as a fixed value lives here. The point is that no other file contains a magic number or string literal that could drift out of sync.

**Exit codes**: `exit_success = 0`, `exit_parse_error = 1`, `exit_file_error = 2`, `exit_analysis_error = 3`, `exit_usage_error = 64`. The usage error code is 64 following the BSD `sysexits.h` convention, which reserves codes 64-78 for program-specific errors. The CLI entry point in `main.v` uses these for every `exit()` call.

**Well-known ports**: Named constants for SSH (22), DNS (53), HTTP (80), HTTPS (443), SMTP (25), NTP (123). The `find_missing_rate_limits` function in `optimizer.v` references `port_ssh` when checking for missing rate limits. The generator uses these indirectly through the `service_ports` map.

**CIDR and network ranges**: `cidr_max_v4 = 32`, `private_ranges` listing RFC 1918 space (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`), and loopback addresses for v4 and v6. The `generate_iptables_hardened` function in `generator.v` iterates `private_ranges` to build anti-spoofing rules that drop packets claiming to originate from private addresses when arriving on the public interface.

**Rate limits**: `ssh_rate_limit = '3/minute'`, `ssh_rate_burst = 5`, `icmp_rate_limit = '1/second'`, `icmp_rate_burst = 5`. These feed directly into the hardened template generation. SSH rate limiting makes brute-force attacks impractical: 3 new connections per minute with a burst allowance of 5. ICMP rate limiting prevents ping flood attacks while still allowing legitimate echo requests.

**Display constants**: Column widths for the rule table (`col_num = 5`, `col_chain = 12`, etc.) and Unicode symbols for the terminal output (`sym_check`, `sym_cross`, `sym_warn`, `sym_arrow`, `sym_bullet`). The display module uses these to build fixed-width columns without depending on terminal width detection.

**Service map**: `service_ports` maps service names to port numbers. This is a `map[string]int` literal. When you run `fwrule harden -s ssh,http,https`, the generator looks up each name in this map via `config.service_ports[svc] or { continue }`. Unknown service names are silently skipped. The map covers ssh, dns, http, https, smtp, ntp, ftp, mysql, pg (PostgreSQL), and redis.

---

## Models Module (models.v)

`src/models/models.v`

This file defines every type the rest of the codebase operates on, plus the CIDR math functions that the analyzer depends on. It is the shared vocabulary between all modules.

### Enums

Six enums: `Protocol`, `Action`, `Table`, `ChainType`, `RuleSource`, `Severity`. Each has a `.str()` method returning the canonical string form. All use `as u8` backing type to keep memory small.

`Protocol`: tcp, udp, icmp, icmpv6, all, sctp, gre. The `all` variant matches any protocol and is the default when a rule does not specify one.

`Action`: Covers the full iptables target set. The `return_action` variant is named that way because `return` is a V keyword. The `.str()` method maps it to `"RETURN"`.

`Table`: filter, nat, mangle, raw, security. Most rulesets only use filter. The complex testdata files use filter and nat together.

`ChainType`: input, output, forward, prerouting, postrouting, custom. The `custom` variant is the catch-all for user-defined chains.

### ConnState as a Flag Enum

```v
@[flag]
pub enum ConnState {
    new_conn
    established
    related
    invalid
    untracked
}
```

Five variants. Because it is a flag enum, each variant is a single bit. `new_conn` is bit 0, `established` is bit 1, `related` is bit 2, and so on. A single `ConnState` value can hold any combination. When the parser reads `ESTABLISHED,RELATED`, it calls `.set(.established)` and `.set(.related)`, producing a value where bits 1 and 2 are set: `0b0110`.

Why bitfields instead of an array? Because the analyzer needs to compare state sets efficiently. "Does the outer rule's state set contain all the inner rule's states?" is a single `outer.states.all(inner.states)` call, which is a bitwise AND under the hood. An array comparison would need nested loops.

### NetworkAddr

Three fields: `address` (string), `cidr` (int, defaults to 32), `negated` (bool). A plain IP like `192.168.1.1` gets `cidr = 32` (a single host). A CIDR like `10.0.0.0/8` gets `cidr = 8`. Negated addresses from `! -s 10.0.0.0/8` get `negated = true`.

### ip_to_u32

The `ip_to_u32` function in `models.v` converts a dotted-quad IP string to a 32-bit unsigned integer for bit-level CIDR math. It splits on `.`, validates that there are exactly four octets, then processes each one. Each octet is validated character-by-character to ensure only ASCII digits are present:

```v
for ch in trimmed.bytes() {
	if ch < `0` || ch > `9` {
		return error('invalid octet in address: ${ip}')
	}
}
val := trimmed.int()
if val < 0 || val > 255 {
	return error('invalid octet in address: ${ip}')
}
result = (result << 8) | u32(val)
```

The per-character validation rejects anything that is not a digit before calling `.int()` for the conversion, and a range check catches values outside 0-255. The shift-and-OR accumulates the four octets into a single 32-bit value.

Walk through `192.168.1.1`:

| Iteration | Octet | result before shift | << 8     | \| octet     | result     |
|-----------|-------|-------------------|----------|-------------|------------|
| 1         | 192   | 0                 | 0        | 192         | 192        |
| 2         | 168   | 192               | 49152    | 49320       | 49320      |
| 3         | 1     | 49320             | 12625920 | 12625921    | 12625921   |
| 4         | 1     | 12625921          | 3232235776| 3232235777 | 3232235777 |

The final value `3232235777` equals `0xC0A80101`, which is `192*2^24 + 168*2^16 + 1*2^8 + 1`. This packs four bytes into one integer, which is the standard representation for IPv4 addresses in networking code.

### cidr_contains

The `cidr_contains` function in `models.v` determines if the `inner` network falls within the `outer` network. Three checks:

First: if `outer.cidr > inner.cidr`, return false immediately. A /24 cannot contain a /8. The outer network must be equal width or broader.

Second: if `outer.cidr == 0`, return true immediately. A /0 network covers the entire IPv4 address space, so any inner network is contained:

```v
if outer.cidr == 0 {
	return true
}
```

Third: compute `shift = 32 - outer.cidr` and compare `(outer_ip >> shift) == (inner_ip >> shift)`. This right-shifts both IPs to discard the host bits, keeping only the network prefix. If the prefixes match, inner is inside outer.

Concrete examples:

Does `10.0.0.0/8` contain `10.1.2.3/32`? outer.cidr (8) <= inner.cidr (32), passes the first check. Shift = 24. `ip_to_u32("10.0.0.0") >> 24 = 10`. `ip_to_u32("10.1.2.3") >> 24 = 10`. Network prefixes match. Yes.

Does `10.0.0.0/8` contain `172.16.0.0/12`? outer.cidr (8) <= inner.cidr (12), passes. Shift = 24. `ip_to_u32("10.0.0.0") >> 24 = 10`. `ip_to_u32("172.16.0.0") >> 24 = 172`. Prefixes differ. No.

Does `192.168.1.0/24` contain `192.168.0.0/16`? outer.cidr (24) > inner.cidr (16). Fails the first check immediately. No. A /24 is narrower than a /16.

Does `192.168.0.0/16` contain `192.168.1.0/24`? outer.cidr (16) <= inner.cidr (24), passes. Shift = 32 - 16 = 16. `ip_to_u32("192.168.0.0") >> 16 = 49320`. `ip_to_u32("192.168.1.0") >> 16 = 49320`. Equal. Yes. The entire 192.168.1.0/24 block sits inside the 192.168.0.0/16 block.

Does `0.0.0.0/0` contain `192.168.1.0/24`? outer.cidr (0) <= inner.cidr (24), passes the first check. The early `outer.cidr == 0` check returns true without any bit math. Yes.

This function is called by the `addr_is_superset` helper in `conflict.v` whenever it needs to determine whether one address range covers another. The shadowed-rules example from the overview (10.0.0.0/8 shadows 10.0.0.0/24) works because `cidr_contains` correctly identifies the /8 as containing the /24.

### PortSpec

Start port, optional end port (defaults to -1 meaning single port), and negated flag. The `effective_end` method normalizes single ports by returning `start` when `end < 0`. This means all port comparison code can treat every `PortSpec` as a range without special-casing singles. The `port_range_contains` function then just checks `outer.start <= inner.start && outer.effective_end() >= inner.effective_end()`.

### MatchCriteria

The struct that holds everything a rule can match on. Eleven fields: protocol (defaults to `.all`), source and destination (both `?NetworkAddr`), src/dst port lists, in/out interface (both `?string`), connection states, ICMP type, rate limit, limit burst, and comment. The option types for address and interface fields are not just a convenience. They encode the semantic difference between "this rule does not filter on source address" and "this rule filters on a specific source address". The conflict detector relies on this distinction: a `none` source means "matches all sources", which is a superset of any specific source.

### Rule

Wraps `MatchCriteria` with metadata: table, chain name, chain type, action, target arguments, line number from the source file, raw text, and source format. The `line_number` field preserves the original file position for error reporting. The `raw_text` field stores the unparsed line for display. The `str` method produces a tab-separated canonical form (`chain\tprotocol\tsource\tdest\tports\taction`) that the diff module uses to compare rules regardless of format.

### Ruleset

A list of rules, a map of chain name to default policy, and the source format. The `pub mut:` visibility makes `rules` and `policies` mutable from outside the module, which the parsers need when building the ruleset incrementally. The `rules_by_chain` method groups rule indices by chain name into `map[string][]int`. Both the analyzer and generator call this to iterate per-chain instead of scanning the flat list repeatedly.

---

## Parsing: Common Functions (common.v)

`src/parser/common.v`

Shared parsing functions used by both the iptables and nftables parsers.

**`parse_network_addr`**: Handles three address formats: plain IP (`192.168.1.1` defaults to /32 CIDR), CIDR notation (`10.0.0.0/8`), and negated (`!172.16.0.0/12`). The negation prefix is stripped first, then the address is split on `/` if present. Validates prefix length is between 0 and 128 (the upper bound accommodates IPv6 addresses even though the current CIDR math only handles v4).

**`parse_port_spec`**: Same pattern as addresses: strip `!` for negation, split on `:` for ranges. Port ranges use colon separator (`1024:65535`), matching the iptables convention. Single ports get `end = -1`. Validates all ports are within 0-65535.

**`parse_port_list`**: Splits a comma-separated string and calls `parse_port_spec` on each piece. Used when the iptables parser encounters `--dports 80,443,8080`.

**`parse_protocol`**: Maps string names and IANA protocol numbers to `Protocol` variants. Accepts `'tcp'`, `'TCP'`, and `'6'` as equivalent. The number mappings (6 for TCP, 17 for UDP, 1 for ICMP, 58 for ICMPv6, 132 for SCTP, 47 for GRE) match IANA assignments, which is what kernel-level tools sometimes emit instead of names.

**`parse_action`**: Maps action strings to `Action` variants. Case insensitive via `.to_upper()`.

**`parse_chain_type`**: Maps chain name strings to `ChainType` variants. Anything not recognized (INPUT, OUTPUT, FORWARD, PREROUTING, POSTROUTING) becomes `.custom`.

**`parse_conn_states`**: Splits a comma-separated state string and sets flags on a `ConnState` bitfield. Starts with `ConnState.zero()` (all bits clear) and calls `.set()` for each recognized name. Unknown state names are silently ignored via the `else {}` branch.

**`detect_format`**: Looks at the first non-empty, non-comment line. Lines starting with `*` (table header like `*filter`) signal iptables. Lines starting with `table` signal nftables. Lines starting with `:` (chain policy) or `-A`/`-I` (rule) also signal iptables. If nothing matches, returns an error. This auto-detection is called in `load_ruleset` in `main.v` so users never need to specify the input format.

---

## Parsing: iptables Format (iptables.v)

`src/parser/iptables.v`

**`tokenize_iptables`**: A byte-by-byte tokenizer that handles quoted strings. Three state variables: `in_quote` tracks whether the scanner is inside a quoted region, `quote_char` remembers which quote character (`"` or `'`) opened it, and `current` accumulates bytes for the token being built.

The scanner iterates over each byte of the line. In normal mode, spaces and tabs flush the current token into the output list. Quote characters switch to quoted mode. In quoted mode, only the matching close quote ends the token; spaces are accumulated as part of the value. The quote characters themselves are stripped from the output, so `"DROPPED: "` becomes `DROPPED: `. This matters for iptables log prefixes and comments that contain spaces.

The parser test in `parser_test.v` validates quoted string handling directly: tokenizing `-j LOG --log-prefix "DROPPED: "` produces 4 tokens, with the fourth being `DROPPED: ` (trailing space preserved, quotes stripped).

**`parse_iptables`**: Line-by-line iteration with three line types:

- Lines starting with `*` set the current table context via `parse_table`. The `current_table` variable carries forward to all subsequent rules until the next table header appears. This is how `iptables_complex.rules` (which has both `*filter` and `*nat` sections) assigns the correct table to each rule.
- Lines starting with `:` define chain policies via `parse_chain_policy`. `:INPUT DROP [0:0]` becomes chain `INPUT` with policy `DROP`. The `[0:0]` packet/byte counters are ignored.
- Lines starting with `-A` or `-I` are parsed as rules by `parse_iptables_rule`, passing the current table and 1-based line number.
- Blank lines, comments (starting with `#`), and `COMMIT` lines are skipped.

**`parse_chain_policy`**: Strips the leading `:`, splits on space, returns the chain name and policy action as a tuple. Uses V's multi-return: `!(string, Action)`.

**`parse_iptables_rule`**: The main rule parser. After tokenizing the line, it initializes mutable variables for every possible rule field, then walks the token array with a mutable index `i` and a match statement covering every recognized flag:

| Flag(s)                        | What it sets                                      |
|-------------------------------|---------------------------------------------------|
| `-A`, `-I`                     | Chain name (next token)                           |
| `-p`, `--protocol`             | Protocol via `parse_protocol`                     |
| `-s`, `--source`               | Source `NetworkAddr`, with negation check          |
| `-d`, `--destination`          | Destination `NetworkAddr`, with negation check     |
| `--sport`, `--source-port`     | Single source port, with negation check            |
| `--dport`, `--destination-port`| Single destination port, with negation check       |
| `--dports`                     | Multiport list via `parse_port_list`              |
| `--sports`                     | Multiport source list                             |
| `-i`, `--in-interface`         | Input interface name                              |
| `-o`, `--out-interface`        | Output interface name                             |
| `--state`, `--ctstate`         | Connection states via `parse_conn_states`         |
| `--icmp-type`                  | ICMP type string                                  |
| `--limit`                      | Rate limit string                                 |
| `--limit-burst`                | Burst count                                       |
| `--comment`                    | Comment string                                    |
| `-j`, `--jump`                 | Action; remaining tokens become target arguments  |
| `-m`, `--match`                | Consumed and skipped (extension name not stored)  |

**Negation handling**: When `!` appears as its own token, a `next_negated` boolean is set to true. The next address or port parsed checks this flag, creates the struct with `negated: true`, and resets the flag to false. This two-phase approach avoids lookahead and keeps the tokenizer completely unaware of iptables semantics.

**Multiport**: The `--dports` token triggers `parse_port_list` from `common.v`, which splits on commas. `-m multiport --dports 80,443` produces two `PortSpec` entries in `dst_ports`. The `-m multiport` part is consumed by the `-m` handler which just advances the index past the extension name. Note that `--dports` replaces the entire `dst_ports` array rather than appending, because multiport defines the complete port list.

**Target arguments**: After parsing the action from `-j`, the parser checks if any remaining tokens start with `--`. If so, it collects all remaining tokens into `target_args`. This captures things like `--log-prefix "DROPPED: "` and `--to-destination 10.0.0.1:8080`.

---

## Parsing: nftables Format (nftables.v)

`src/parser/nftables.v`

nftables uses a block structure (`table { chain { rule } }`) instead of flat flags. The parser tracks nesting through a hierarchy of functions.

**`parse_nftables`**: Top-level loop. When it sees a line starting with `table`, it calls `parse_nft_table` which returns both a `Table` value and the next line index to process. This tuple return (`!(Table, int)`) is the V idiom for consuming variable numbers of lines without mutation of a shared counter.

**`parse_nft_table`**: Extracts the table name from the header by filtering out known family keywords (`table`, `inet`, `ip`, `ip6`, `arp`, `bridge`, `netdev`). The first token that is not one of these keywords is the table name. This handles all nftables family prefixes without maintaining an explicit list of valid families. It then scans lines until the closing `}`, delegating lines starting with `chain` to `parse_nft_chain`.

**`parse_nft_chain`**: Extracts the chain name from lines like `chain input {`, uppercases it to normalize to the iptables convention (`input` becomes `INPUT`). Lines starting with `type` are chain metadata (hook declaration with policy). All other non-empty, non-comment lines are parsed as rules. A failed rule parse uses `or { i++; continue }` to skip unparseable lines without aborting the file.

**`extract_nft_policy`**: Parses `type filter hook input priority 0; policy drop;`. It splits on `;`, finds the segment starting with `policy`, strips the keyword, and parses the remaining text as an action. Returns `?Action` so chains without explicit policies return `none`.

**`parse_nft_rule`**: Token-based like the iptables parser, but matching nftables keywords instead of dash-flags. The tokens are produced by splitting the line on spaces, then filtering empties.

| Expression                    | What it sets                                    |
|------------------------------|------------------------------------------------|
| `tcp`, `udp`                  | Protocol, then `parse_nft_port_match` for ports|
| `ip saddr X`                  | Source `NetworkAddr`                           |
| `ip daddr X`                  | Destination `NetworkAddr`                      |
| `ip protocol X`               | Protocol by name                               |
| `ct state X`                  | Connection states via `parse_conn_states`      |
| `iifname X`, `iif X`          | Input interface (quotes stripped)              |
| `oifname X`, `oif X`          | Output interface (quotes stripped)             |
| `limit rate X`                | Rate limit (multi-token, collects until action)|
| `log`                          | LOG action with optional `prefix` argument     |
| `counter`                      | Skipped (counter is metadata, not match logic) |
| `comment X`                    | Comment string (quotes stripped)               |
| `accept`/`drop`/`reject`/etc. | Terminal action                                |

**Rate limit parsing**: The `limit rate` expression in nftables spans a variable number of tokens, which makes it one of the trickier parsing sequences. After seeing `limit` and then `rate`, the parser enters a collection loop that accumulates tokens into `rate_parts` until it encounters an action keyword (`accept`, `drop`, `reject`, `log`) or `counter`. The collected tokens are joined with spaces and stored as the rate string. For a rule like `limit rate 3/minute burst 5 packets accept`, this produces `limit_rate = "3/minute burst 5 packets"`. The `continue` after storing the rate ensures the loop re-examines the action token in the next iteration instead of consuming it as part of the rate string.

**Action as bare keyword**: In nftables, actions are not flagged with `-j`. They appear as standalone tokens at the end of the rule: `accept`, `drop`, `reject`, `masquerade`, `return`, `queue`. The parser checks for these and sets the action directly. The `log` action gets special handling because it can have a `prefix` argument that needs to be captured into `target_args`. If no action keyword is found by the end of the tokens, the parser returns an error:

```v
final_action := action or { return error('no action found in rule: ${line}') }
```

**Set syntax** (the `parse_nft_port_match` function): nftables uses `{ 80, 443 }` for port sets. When the token after `dport` is `{`, the parser collects tokens until `}`, strips commas with `.replace(',', '')`, and parses each as a port spec. The comma removal is necessary because the space-based tokenization leaves commas attached to port numbers (`"80,"` instead of `"80"`). Single ports without braces take the simpler path, parsing one token directly.

The `parse_nft_port_match` function returns the updated index so the caller can resume iteration at the right position. Both `is_dport` and `is_sport` are determined by checking the token at the start position. The parsed ports are appended to the appropriate mutable array (`dst_ports` or `src_ports`) that was passed by reference.

**Protocol and port coupling**: In nftables, protocol and port are part of the same expression: `tcp dport 22`. The parser handles this by setting the protocol when it sees `tcp` or `udp`, then immediately calling `parse_nft_port_match` to check if the next token is `dport` or `sport`. If it is, the function handles the port parsing and returns the new index. If the next token is neither `dport` nor `sport`, the function returns the index unchanged and no ports are added. The `continue` skips the default `i++` at the bottom of the loop since the index has already been advanced by the port matcher.

---

## Conflict Detection (conflict.v)

`src/analyzer/conflict.v`

**`analyze_conflicts`**: Gets the chain-grouped indices from `rs.rules_by_chain()`, then for each chain runs four detection passes: `find_duplicates`, `find_shadowed_rules`, `find_contradictions`, `find_redundant_rules`. Grouping by chain first is critical because netfilter evaluates rules within a single chain sequentially. A rule in INPUT cannot shadow a rule in FORWARD since they process different traffic flows entirely.

### match_is_superset

The central function for conflict detection. Determines if `outer` criteria match a strict superset of the traffic that `inner` criteria match. Every dimension must pass the superset test. The function returns false at the first dimension that fails, providing an early exit.

1. **Protocol**: If outer is `.all`, it matches any protocol, so it is always a superset. If outer specifies a protocol that differs from inner's, it cannot be a superset.

2. **Source address**: Delegates to `addr_is_superset`. The logic:
   - outer is `none` (no source filter) -> superset of anything, return true
   - outer is some, inner is `none` (inner matches everything) -> outer cannot cover "everything", return false
   - both are some -> delegate to `cidr_contains` from models.v

3. **Destination address**: Same pattern as source.

4. **Destination and source ports**: Delegates to `ports_is_superset`. Empty outer list means "match all ports", which is a superset of anything. Non-empty outer must cover every port in inner's list. For each inner port range, at least one outer port range must fully contain it (checked via `port_range_contains`).

5. **Interfaces**: Delegates to `iface_is_superset`. `none` outer is superset. Both present must be equal strings.

6. **Connection states**: If outer has state constraints (not empty), inner must have all of them. `outer.states.all(inner.states)` performs a bitwise check. If outer has no state constraints, it passes regardless.

### matches_overlap

Similar to `match_is_superset` but bidirectional. Two criteria overlap if they could match the same packet. For protocols, overlap requires either one being `.all` or both matching. For addresses, `addrs_overlap` checks if either direction of `cidr_contains` holds (A contains B or B contains A). For ports, `ports_overlap` checks if any pair of port ranges from the two lists intersect using `pa.start <= pb.effective_end() && pb.start <= pa.effective_end()`.

### Detection Passes

**`find_shadowed_rules`**: Nested loop with `i < j`, so rule `i` always appears before rule `j` in the chain. A shadow is detected when `match_is_superset(rules[i].criteria, rules[j].criteria)` is true AND the two rules have different actions (`rules[i].action != rules[j].action`):

```v
if match_is_superset(rules[i].criteria, rules[j].criteria)
	&& rules[i].action != rules[j].action {
	findings << Finding{
		severity:     .critical
		title:        'Shadowed rule detected'
		description:  'Rule ${indices[j] + 1} (${rules[j].action.str()}) can never match because rule ${
			indices[i] + 1} (${rules[i].action.str()}) catches all its traffic first'
		rule_indices: [indices[i], indices[j]]
		suggestion:   'Remove rule ${indices[j] + 1} or reorder it before rule ${
			indices[i] + 1}'
	}
}
```

The action comparison is key: if both rules have the same action, the later rule is redundant (wasteful but harmless) rather than shadowed (actively wrong). Shadows only fire when the actions differ, because that means the later rule's intended behavior can never take effect. Since netfilter processes rules top to bottom and stops at the first match, the later rule is dead code. This is CRITICAL severity because the rule has zero effect regardless of intent.

Concrete scenario: rule 7 is `DROP tcp/22` (block SSH from anywhere) and rule 8 is `ACCEPT tcp/22 from 10.0.0.0/8` (allow SSH from the 10.x range). Rule 7 has no source constraint, so `match_is_superset(rule7, rule8)` is true: the protocol matches (both TCP), `addr_is_superset(none, 10.0.0.0/8)` is true (no constraint is superset of any constraint), and port 22 matches port 22. The actions differ (DROP vs ACCEPT), so this is a shadow. Rule 8 never fires.

**`find_contradictions`**: Also `i < j`. Two rules contradict when their matches overlap and their actions conflict (one allows, the other denies). The key subtlety is that if one rule is a pure superset of the other, the function skips it. That case is already reported as a shadow. Contradictions only apply to partial overlaps where some packets match both rules but neither rule completely covers the other.

Concrete scenario: rule 11 is `ACCEPT tcp/443 from 192.168.1.0/24` and rule 12 is `DROP tcp/443 from 192.168.0.0/16`. Their source addresses overlap (the /24 is inside the /16), ports match, and actions conflict (ACCEPT vs DROP). But rule 12 is not a pure superset of rule 11 because rule 12 also matches sources like 192.168.2.0/24 that rule 11 does not. So this is a contradiction, not a shadow.

The `actions_conflict` function defines conflict as one "allow-like" (ACCEPT) and one "deny-like" (DROP or REJECT). DROP vs REJECT is not a conflict (both deny). ACCEPT vs ACCEPT is not a conflict (both allow).

**`find_duplicates`**: Uses `criteria_equal` combined with action equality. Two rules are duplicates only when every field matches exactly: same protocol, same source, same destination, same ports, same interfaces, same states, and same action. This is the simplest detection pass.

**`find_redundant_rules`**: Superset relationship with the same action. A broad `ACCEPT tcp` and a narrow `ACCEPT tcp dport 80` for the same chain mean the narrow rule does nothing because the broad rule already accepts all TCP, including port 80. This differs from shadows in two ways: the actions must match, and the finding is INFO severity rather than CRITICAL (the narrow rule is harmless, just wasteful). The check explicitly excludes exact duplicates (`!criteria_equal(...)`) since those are reported by `find_duplicates`.

### Helper Functions

The conflict detector has a layer of helper functions that handle the option-type unwrapping and comparison logic for each field type. Understanding these is key to understanding why the superset and overlap checks work correctly.

**`addr_is_superset`**: This function demonstrates the option-type pattern used throughout the conflict module. The logic reads as a truth table:

| outer   | inner   | result | reasoning                                          |
|---------|---------|--------|----------------------------------------------------|
| `none`  | `none`  | true   | no filter is superset of no filter                 |
| `none`  | some    | true   | no filter matches everything, superset of anything |
| some    | `none`  | false  | specific filter cannot cover "everything"          |
| some    | some    | cidr   | delegate to `cidr_contains`                        |

This pattern repeats for `iface_is_superset`: `none` outer is superset of anything, both present must be equal strings. And for `ports_is_superset`: empty outer list is superset of anything, non-empty outer must cover all inner ports.

The consistent rule is: "no constraint" is always a superset (it matches everything), and "some constraint" can only be a superset if it demonstrably covers the other.

**`criteria_equal`**: Field-by-field equality check. Uses `addrs_equal` for address comparison: both `none` is equal, both present must match address, CIDR, and negation flag, one `none` and one present is not equal. Uses `ports_equal` for port lists: must be same length, and each pair must match start, effective_end, and negation. Uses `opt_str_equal` for optional strings like interface names: both `none` is equal, both present must be identical, mixed is not equal.

**`addrs_overlap`**: If either address is `none`, overlap is true (an unfiltered dimension matches everything, so any specific value overlaps with it). If both are present with different negation flags, overlap is conservatively assumed true because reasoning about the intersection of a negated range and a non-negated range is complex. Otherwise, check `cidr_contains` in both directions: if A contains B or B contains A, they overlap.

**`ports_overlap`**: If either port list is empty, overlap is true (no port filter means all ports). Otherwise, check every pair from the two lists. Two port ranges overlap when `a.start <= b.effective_end() && b.start <= a.effective_end()`. This is the standard interval overlap test: two intervals [a,b] and [c,d] overlap when a <= d and c <= b.

---

## Optimization Suggestions (optimizer.v)

`src/analyzer/optimizer.v`

**`suggest_optimizations`**: Groups rules by chain and runs seven checks per chain (`find_mergeable_ports`, `suggest_reordering`, `find_missing_rate_limits`, `find_missing_conntrack`, `find_unreachable_after_drop`, `find_overly_permissive`, `find_redundant_terminal_drop`), plus one global check (`find_missing_logging`).

**`find_mergeable_ports`**: Groups single-port rules by a composite key of `protocol|source|destination|action`. Rules with identical keys differ only in destination port and could be merged into one multiport rule. For example, three separate rules accepting TCP on ports 80, 443, and 8080 from the same source would share the key `tcp|*|*|accept` and could become one rule with `--dports 80,443,8080`.

Groups with 2-15 rules are flagged. The upper bound of 15 comes from `config.multiport_max`, which is the iptables multiport extension limit. The kernel's `xt_multiport` module supports at most 15 ports per rule. Groups larger than 15 cannot use multiport and are skipped.

The function only considers rules with exactly one destination port (`rule.criteria.dst_ports.len != 1`). Rules with port ranges or multiple ports are already using some form of multi-matching and are not candidates for further merging.

**`find_missing_rate_limits`**: Two passes. First pass: build a map of all ports that already have rate limiting somewhere in the chain. This prevents false positives when a dedicated rate-limit rule exists alongside a plain accept rule for the same port. Second pass: check SSH rules (port 22) that ACCEPT without rate limiting. SSH is the only port checked because it is the primary brute-force target on internet-facing servers.

**`find_missing_conntrack`**: Scans for a rule with `.has(.established)` in its states. Three outcomes: no conntrack rule exists and the chain has more than 2 rules (WARNING), conntrack exists but at position 3 or later in the chain (INFO, because it works but costs unnecessary cycles), or conntrack is in the first few positions (no finding). The ESTABLISHED/RELATED rule is the single highest-impact performance optimization in any firewall. On a busy server, the vast majority of packets belong to existing connections. Without early conntrack, every one of those packets traverses the entire chain.

**`suggest_reordering`**: Skips the first three rules in each chain since those are typically loopback, conntrack, and invalid-drop rules that should stay at the top. For remaining rules, if a rule matches a high-traffic port (HTTP 80, HTTPS 443, DNS 53 from `config`) and is an ACCEPT, it suggests moving it earlier. The rationale: netfilter evaluates rules sequentially, so putting frequently-hit rules near the top reduces the average number of comparisons per packet.

**`find_missing_logging`**: Global check, not per-chain. For each chain with a DROP or REJECT default policy, it checks if any LOG rule exists in that chain. Without logging, dropped packets disappear silently and diagnosing connectivity issues becomes guesswork.

---

## Hardened Generation (generator.v)

`src/generator/generator.v`

**`generate_hardened`**: Dispatches to `generate_iptables_hardened` or `generate_nftables_hardened` based on the requested format. Both generators follow the same template order.

### generate_iptables_hardened

Builds a complete iptables-save format ruleset as an array of strings joined with newlines. The template order is not arbitrary. It reflects the packet processing priority of a production firewall, where early rules handle the highest-volume traffic and later rules handle progressively rarer cases:

1. **Default deny**: `:INPUT DROP [0:0]`, `:FORWARD DROP [0:0]`, `:OUTPUT ACCEPT [0:0]`. Whitelisting approach: deny everything, then allow only what is needed.
2. **Loopback**: Allow all traffic on the `lo` interface. Blocking loopback breaks most applications that communicate internally.
3. **Conntrack**: Accept ESTABLISHED/RELATED (packets belonging to existing connections) and drop INVALID. Placed early for performance.
4. **Anti-spoofing**: Iterates `config.private_ranges` and drops packets from RFC 1918 addresses arriving on the public interface. A packet claiming to be from `10.0.0.0/8` on your internet-facing `eth0` is spoofed.
5. **ICMP**: Rate-limited echo-request at `config.icmp_rate_limit` (1/second). Echo-reply, destination-unreachable, and time-exceeded are always allowed since they are essential for path MTU discovery and traceroute.
6. **Services**: Per-service rules driven by `config.service_ports`. SSH gets conntrack NEW state and rate limiting at `config.ssh_rate_limit`. DNS gets both TCP and UDP because zone transfers use TCP. NTP gets UDP only. Everything else defaults to TCP.
7. **Logging**: Rate-limited LOG with `config.log_prefix_dropped` before the final drop. Rate limiting prevents log flooding during a DDoS.
8. **Final DROP**: Explicit drop as a safety net even though the chain policy is already DROP. Defense in depth.

### generate_nftables_hardened

Same template in nftables syntax with `table inet filter { chain input { ... } }` block nesting. Syntactic differences: `ct state established,related accept` instead of `-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT`. `ip saddr 10.0.0.0/8 drop` instead of `-s 10.0.0.0/8 -j DROP`. `limit rate 3/minute burst 5 packets` instead of `-m limit --limit 3/minute --limit-burst 5`. Also includes `chain forward` and `chain output` declarations.

### Format Export

**`export_ruleset`**: Dispatches to `export_as_iptables` or `export_as_nftables`.

**`export_as_iptables`**: Iterates all rules, tracking seen tables in the `tables_seen` map. When a new table appears, the function emits a `COMMIT` for the previous table (if any), then `*tablename`, then all chain policies. Each rule is converted by `rule_to_iptables` and appended. A final `COMMIT` is emitted after all rules. This handles multi-table rulesets: a ruleset with filter and nat rules produces two `*filter ... COMMIT` and `*nat ... COMMIT` blocks.

**`export_as_nftables`**: Groups chains by table using a `table_chains` map of type `map[string]map[string][]int`. The first pass iterates all rules and populates this map, grouping rule indices by table name and chain name:

```v
mut table_chains := map[string]map[string][]int{}
for i, rule in rs.rules {
	tbl := rule.table.str()
	if tbl !in table_chains {
		table_chains[tbl] = map[string][]int{}
	}
	table_chains[tbl][rule.chain] << i
}
```

The second pass iterates the `table_chains` map. For each table, it emits `table inet X {`. For each chain within that table, it looks up the policy and emits the chain block. Standard chains (INPUT, OUTPUT, FORWARD, PREROUTING, POSTROUTING) get hook declarations with `type filter hook X priority 0; policy Y;`. The hook name is derived from the chain name by a match statement that maps `INPUT` to `input`, `OUTPUT` to `output`, etc. Custom chains get no hook declaration since the match returns an empty string, and the empty string check skips the hook line. Each rule index is then converted via `rule_to_nftables` and emitted inside the chain block.

This table-grouped approach produces correct nftables output even when the source ruleset has rules from multiple tables interleaved, because the grouping map collects all chains per table before any output is generated.

### Rule Conversion Functions

**`rule_to_iptables`**: Builds an iptables rule string by conditionally appending parts to a `[]string` array that is joined with spaces. The emission order follows iptables convention:

1. Chain: `-A ${r.chain}` (always present)
2. Protocol: `-p ${r.criteria.protocol.str()}` (skipped when `.all`)
3. Source: `-s` or `! -s` with `address/cidr` (only if source is not `none`)
4. Destination: `-d` or `! -d` (only if destination is not `none`)
5. Interfaces: `-i ${iface}` and/or `-o ${oface}` (only if present)
6. Conntrack: `-m conntrack --ctstate NEW,ESTABLISHED,RELATED,INVALID` built by checking each flag bit individually
7. Ports: `--dport X` for single port, `-m multiport --dports X,Y,Z` for multiple
8. Rate limit: `-m limit --limit X --limit-burst Y` (only if limit_rate is set)
9. Action: `-j ${r.action.str()}` followed by any `target_args`

The conntrack state reconstruction is the inverse of `parse_conn_states`: it checks each flag with `.has()` and builds an array of state name strings, then joins them with commas. This round-trips correctly through parse -> model -> emit.

**`rule_to_nftables`**: Same conditional emission pattern, different syntax. The emission order follows nftables convention:

1. Interfaces: `iifname "X"` and/or `oifname "X"` with quoted values
2. Source: `ip saddr [!= ]address/cidr` using `!=` for negation instead of `!`
3. Destination: `ip daddr [!= ]address/cidr`
4. Conntrack: `ct state new,established,related,invalid` (lowercase, comma-separated)
5. Protocol and ports combined: `tcp dport 443` for single, `tcp dport { 80, 443 }` for set syntax, `ip protocol tcp` when protocol is specified but no ports
6. Rate limit: `limit rate X` inline
7. Action: lowercase keyword (`accept`, `drop`, `reject`); `log` with optional `prefix` argument handled specially

The key structural difference from `rule_to_iptables` is step 5: in nftables, protocol and port are a single expression. When there is a protocol but no ports, the rule uses `ip protocol tcp`. When there are ports, the protocol name is part of the port expression: `tcp dport 80`. This is handled by a three-way `if/else if/else` block in the protocol emission logic.

---

## Display Module (display.v)

`src/display/display.v`

The display module is the only module that depends on V's `term` package for colored output. It never touches parser, analyzer, or generator internals. It reads `models` types and `config` constants only.

**`print_banner`**: Draws a box using Unicode box-drawing characters with `term.bold()` and `term.cyan()`. Shows the app name and `config.version`. The banner uses the `term.dim()` function for lower-contrast text like the version number and subtitle.

**`print_rule_table`**: Builds a fixed-width table using column constants from config (`col_num = 5`, `col_chain = 12`, `col_proto = 8`, `col_source = 22`, `col_dest = 22`, `col_ports = 16`, `col_action = 12`). The header line concatenates `pad_right` calls for each column label. A separator line of dashes repeats to the total width. Each rule gets one row with its 1-based index, chain name, protocol, source, destination, ports, and colorized action.

The `format_addr` function unwraps the option type: if the address is `none` (no source or destination constraint), it returns `'*'`. Otherwise it calls `truncate` to fit the address within the column width. The `format_ports` function does the same for port lists, joining multiple ports with commas before truncation. The `colorize_action` function maps ACCEPT to `term.green()`, DROP and REJECT to `term.red()`, and LOG to `term.yellow()`. Other actions are not colorized.

**`print_finding`**: Renders a single finding. The severity badge is wrapped in brackets and colored via `colorize_severity`: `[CRITICAL]` in bold red, `[WARNING]` in yellow, `[INFO]` in cyan. The title is bolded. Affected rule numbers are converted from 0-indexed (internal representation) to 1-indexed (user-facing) by `.map('${it + 1}')`. The suggestion line uses `config.sym_arrow` (a Unicode right arrow) as a prefix and `term.green()` for the text, making actionable advice visually distinct from descriptive text.

**`print_findings`**: First counts findings by severity category (critical, warning, info), then prints a summary header with color-coded counts, then iterates each finding and prints it. If no findings exist, prints `config.sym_check` (a Unicode checkmark) in green with "No issues found".

**`print_summary`**: Shows the ruleset format, total rule count, chain count, and per-chain breakdown. Each chain entry shows its rule count and colorized default policy. The policy lookup uses `if p := rs.policies[chain_name]` to handle chains without explicit policies (which get a dimmed dash character).

**`print_diff`**: Compares two rulesets by converting each to a set of canonical strings. The `build_rule_set` function iterates all rules and creates a `map[string]bool` using `Rule.str()` as the key. The canonical form is tab-separated `chain\tprotocol\tsource\tdest\tports\taction`, which normalizes both iptables and nftables rules to the same representation. Set differences are computed by iterating each map and checking membership in the other. Rules unique to left get a red `-` prefix. Rules unique to right get a green `+` prefix. Identical rulesets print "Rulesets are equivalent" with a green checkmark.

**Utility functions**: `pad_right` right-pads a string with spaces to a target width. If the string is already at or beyond the target width, it returns unchanged. `truncate` cuts strings that exceed a maximum length and appends `...` as an ellipsis indicator. For maximum lengths of 3 or less, it skips the ellipsis and just truncates, since there would not be room for both content and the ellipsis marker.

---

## Testing

V test conventions: files end in `_test.v`, functions are prefixed with `test_`, and assertions use the `assert` keyword. No test framework is needed.

**Module-internal access.** Test files declare themselves in the same module as the code they test. `src/parser/parser_test.v` uses `module parser`, giving it access to private functions like `tokenize_iptables`. `src/analyzer/analyzer_test.v` uses `module analyzer` to directly call `find_shadowed_rules`, `match_is_superset`, `ports_overlap`, and other unexported functions. This is the same pattern as Go's `_test.go` files in the same package.

**Testdata files.** Tests use `@VMODROOT`, a compile-time constant that resolves to the directory containing `v.mod` (the project root). For example, `os.read_file(@VMODROOT + '/testdata/iptables_basic.rules')` loads fixture files with a path that works regardless of the current working directory.

**Running tests.** `v test src/` from the project root discovers and runs all `_test.v` files in parallel. The Justfile wraps this as `just test`. Individual test output with timing uses `just test-verbose`, which passes the `-stats` flag. Tests are designed to be fast: no external dependencies, no network calls, no file creation. Everything reads from the testdata directory or constructs structs inline.

**Test isolation.** Each test function constructs its own data and makes assertions. There is no shared test state, no setup/teardown, and no test ordering dependencies. A test like `test_find_shadowed_rule` in `analyzer_test.v` creates two `Rule` structs with specific criteria, calls the private `find_shadowed_rules` function directly, and asserts the result has the expected severity and title.

**Parser tests** (`src/parser/parser_test.v`): Organized in three tiers.

The first tier is unit tests for each shared parse function. `parse_network_addr` is tested with plain IP (asserts `cidr == 32`), CIDR /8, CIDR /24, and negated (asserts `negated == true`). `parse_port_spec` covers single port, range (asserts `start == 1024` and `end == 65535`), and negated. `parse_port_list` tests comma-separated parsing with and without spaces. `parse_protocol` verifies name parsing (tcp, udp, icmp), IANA number parsing (`'6'` -> tcp, `'17'` -> udp), and case insensitivity (`'TCP'` -> tcp). `parse_action` covers ACCEPT, DROP, REJECT, LOG, MASQUERADE. `parse_table` covers filter, nat, mangle. `parse_chain_type` checks standard types and the custom fallback. `parse_conn_states` verifies single state, multiple states, all four states, and case-insensitive input.

The second tier is format detection and tokenizer tests. `detect_format` is tested with iptables table headers, chain policies, rule lines, nftables blocks, and inputs starting with comments (verifies the comment is skipped). The tokenizer gets three tests: basic splitting (8 tokens from a simple rule), double-quoted strings with embedded spaces (verifies `"DROPPED: "` becomes `DROPPED: ` with space preserved and quotes stripped), and single-quoted strings (verifies `'my rule'` becomes `my rule`).

The third tier is integration tests loading real testdata files. `test_parse_iptables_basic_rule_count` loads `iptables_basic.rules` and asserts 9 rules. `test_parse_iptables_basic_policies` checks that INPUT is DROP, FORWARD is DROP, OUTPUT is ACCEPT. `test_parse_iptables_basic_ssh_rule` verifies the SSH rule has protocol TCP, one destination port of 22, and action ACCEPT. `test_parse_iptables_basic_conntrack` checks that the conntrack rule has both `.established` and `.related` states set. `test_parse_nftables_basic_rule_count` loads `nftables_basic.rules` and asserts 8 rules. Complex file tests verify multiport rules from `iptables_complex.rules`, rate limit extraction, and NAT table MASQUERADE rules.

**Analyzer tests** (`src/analyzer/analyzer_test.v`): The most comprehensive test file, organized into detection tests, helper function tests, and optimizer tests.

Detection tests use manually constructed `Rule` structs to test each pass in isolation. `test_find_shadowed_rule` creates a broad TCP rule (no port filter) and a narrow TCP/port-80 rule, calls `find_shadowed_rules` directly, and asserts one CRITICAL finding with "Shadowed" in the title. `test_find_contradiction` creates two rules with overlapping criteria (TCP port 80 from 192.168.1.0/24 with ACCEPT vs TCP port 80 to 10.0.0.0/8 with DROP), asserts one WARNING finding. `test_find_duplicate` passes the same rule twice, asserts one WARNING. `test_find_redundant` uses a broad TCP/ACCEPT and narrow TCP-port-80/ACCEPT, asserts one INFO finding. `test_no_false_positives_disjoint_rules` creates TCP/22 and UDP/53 rules, runs `analyze_conflicts` on a full `Ruleset`, and asserts no CRITICAL findings. This test is important because it validates that rules on different protocols are not falsely flagged.

Helper function tests exercise the building blocks. `matches_overlap` is tested with: same protocol and port (overlaps), different protocols (does not overlap), `.all` protocol (overlaps with anything), non-overlapping ports (tcp/80 vs tcp/443), empty port list matching everything. `match_is_superset` is tested with: broader criteria covering narrower, narrower criteria not covering broader, `.all` protocol as superset of specific, CIDR containment via 10.0.0.0/8 containing 10.1.2.0/24, CIDR non-containment via 10.0.0.0/24 not containing 172.16.0.0/24.

`criteria_equal` tests: identical criteria, different ports, different protocol, matching addresses, `none` vs `some` address. `actions_conflict` tests: accept/drop (true), accept/reject (true), drop/accept (true), accept/accept (false), drop/drop (false), drop/reject (false). Port helpers: `ports_overlap` for same port, different ports, range containing single, empty lists. `ports_is_superset` for empty outer (superset), empty inner (not superset), range covering single, single not covering other. Address helpers: `addr_is_superset` with broader CIDR, `none` outer (always superset), `none` inner (not superset), both `none` (true).

Optimizer tests: `test_find_mergeable_ports` creates three TCP rules on ports 80, 443, 8080 with same protocol/source/dest/action, asserts one finding suggesting merge. `test_find_missing_rate_limits_ssh` creates one TCP/22 ACCEPT rule without rate limiting, asserts one WARNING finding. `test_find_missing_conntrack_empty` passes empty inputs, asserts no findings (edge case guard). `test_opt_str_equal_*` tests verify the optional string equality helper with both-none, same-value, different-value, and one-none cases.

**Generator tests** (`src/generator/generator_test.v`): Tests the hardened template in both formats. The testing strategy for generators is string containment: generate the output and assert that specific substrings appear. This verifies that the right rules are present without being brittle to exact whitespace or ordering within sections.

iptables hardened tests verify: default deny policies (checks for `:INPUT DROP` and `:FORWARD DROP`), loopback rules (checks for `-A INPUT -i lo -j ACCEPT`), conntrack (checks for `--ctstate ESTABLISHED,RELATED -j ACCEPT` and `--ctstate INVALID -j DROP`), SSH with rate limit (checks that `--dport 22`, `--limit 3/minute`, and `--limit-burst 5` all appear), HTTP/HTTPS ports, anti-spoofing for all three RFC 1918 ranges (individually checks `-s 10.0.0.0/8`, `-s 172.16.0.0/12`, `-s 192.168.0.0/16`), ICMP rate limiting, logging prefix, final DROP as the last INPUT rule (scans for the last `-A INPUT` line and asserts it equals `-A INPUT -j DROP`), COMMIT markers, DNS dual-protocol (checks both `-p tcp --dport 53` and `-p udp --dport 53`), NTP UDP-only (checks `-p udp --dport 123`), and custom interface name (passes `'ens192'` and checks for `-i ens192`).

nftables hardened tests verify: table/chain structure, conntrack syntax (checks `ct state established,related accept`), SSH rate limit, anti-spoofing (checks `ip saddr 10.0.0.0/8 drop`), loopback (checks `iifname "lo" accept`), DNS dual-protocol.

`rule_to_iptables` unit tests: Each test constructs a `Rule` struct with specific criteria and asserts the output string contains the expected flags. TCP port test checks for `-A INPUT`, `-p tcp`, `--dport 80`, `-j ACCEPT`. Negated source test checks for `! -s 10.0.0.0/8`. Multiport test checks for `-m multiport --dports`.

`rule_to_nftables` unit tests: Same pattern with nftables syntax. Negated source checks for `!= 10.0.0.0/8` (nftables negation syntax). Multiport set checks for `tcp dport {` with both port numbers present. Log with prefix checks that `log prefix "DROPPED: "` appears as a single expression.

Export integration tests: `test_export_ruleset_iptables` creates a minimal `Ruleset` with one rule and one policy, exports it, and checks the output contains `*filter`, `:INPUT DROP`, `-A INPUT`, and `COMMIT`. `test_export_ruleset_nftables` does the same and checks for `table inet filter`, `chain input`, `tcp dport 80`. `test_export_empty_ruleset` verifies that exporting an empty ruleset does not crash.
