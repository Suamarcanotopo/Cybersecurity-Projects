"""
©AngelaMos | 2026
severity.py

Severity classification for normalized log events

Classifies events by first checking a fixed set of high-signal event
types, then pattern-matching against pre-compiled regexes across four
tiers (critical, high, medium, low). Called immediately after
normalization for every ingested and scenario-generated event.

Key exports:
  classify - returns a Severity string for a normalized event dict

Connects to:
  models/LogEvent.py - imports Severity for return values
  controllers/log_ctrl.py - calls classify before persisting
  scenarios/runner.py - calls classify for each playbook event
"""

import re
from typing import Any

from app.models.LogEvent import Severity


CRITICAL_PATTERNS = [
    re.compile(r"privilege.?escalat",
               re.IGNORECASE),
    re.compile(r"root.?compromise",
               re.IGNORECASE),
    re.compile(r"data.?exfiltrat",
               re.IGNORECASE),
    re.compile(r"ransomware",
               re.IGNORECASE),
    re.compile(r"command.?and.?control",
               re.IGNORECASE),
    re.compile(r"c2.?beacon",
               re.IGNORECASE),
]

HIGH_PATTERNS = [
    re.compile(r"brute.?force",
               re.IGNORECASE),
    re.compile(r"lateral.?movement",
               re.IGNORECASE),
    re.compile(r"reverse.?shell",
               re.IGNORECASE),
    re.compile(r"malware",
               re.IGNORECASE),
    re.compile(r"exploit",
               re.IGNORECASE),
    re.compile(r"unauthorized.?access",
               re.IGNORECASE),
]

MEDIUM_PATTERNS = [
    re.compile(r"login.?fail",
               re.IGNORECASE),
    re.compile(r"authentication.?fail",
               re.IGNORECASE),
    re.compile(r"suspicious",
               re.IGNORECASE),
    re.compile(r"port.?scan",
               re.IGNORECASE),
    re.compile(r"denied",
               re.IGNORECASE),
    re.compile(r"blocked",
               re.IGNORECASE),
]

LOW_PATTERNS = [
    re.compile(r"warning",
               re.IGNORECASE),
    re.compile(r"policy.?violation",
               re.IGNORECASE),
    re.compile(r"anomal",
               re.IGNORECASE),
]

SEVERITY_TIERS = [
    (Severity.CRITICAL,
     CRITICAL_PATTERNS),
    (Severity.HIGH,
     HIGH_PATTERNS),
    (Severity.MEDIUM,
     MEDIUM_PATTERNS),
    (Severity.LOW,
     LOW_PATTERNS),
]

HIGH_SEVERITY_EVENT_TYPES = frozenset(
    {
        "privilege_escalation",
        "data_exfiltration",
        "c2_communication",
        "reverse_shell",
    }
)

MEDIUM_SEVERITY_EVENT_TYPES = frozenset(
    {
        "login_failure",
        "port_scan",
        "firewall_deny",
        "ids_alert",
    }
)


def classify(normalized: dict[str, Any]) -> str:
    """
    Determine severity from event type and content pattern matching
    """
    event_type = normalized.get("event_type", "")

    if event_type in HIGH_SEVERITY_EVENT_TYPES:
        return Severity.HIGH
    if event_type in MEDIUM_SEVERITY_EVENT_TYPES:
        return Severity.MEDIUM

    searchable = _build_searchable_text(normalized)

    for severity, patterns in SEVERITY_TIERS:
        for pattern in patterns:
            if pattern.search(searchable):
                return severity

    return Severity.INFO


def _build_searchable_text(normalized: dict[str, Any]) -> str:
    """
    Concatenate relevant fields into a single string for pattern matching
    """
    parts = [
        str(normalized.get("event_type",
                           "")),
        str(normalized.get("message",
                           "")),
        str(normalized.get("normalized",
                           {}).get("message",
                                   "")),
        str(normalized.get("normalized",
                           {}).get("signature_name",
                                   "")),
        str(normalized.get("normalized",
                           {}).get("classification",
                                   "")),
        str(normalized.get("normalized",
                           {}).get("command_line",
                                   "")),
    ]
    return " ".join(parts)
