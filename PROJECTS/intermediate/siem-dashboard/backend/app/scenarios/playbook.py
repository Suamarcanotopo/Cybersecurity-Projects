"""
©AngelaMos | 2026
playbook.py

YAML playbook loading for attack scenarios

Parses scenario playbook files into typed Playbook and PlaybookEvent
dataclasses. Playbook.load reads a single file for starting a run;
Playbook.list_available scans the playbooks directory and returns
lightweight metadata without loading full event lists.

Key exports:
  Playbook - dataclass with load() and list_available() class methods
  PlaybookEvent - dataclass for a single timed event in a playbook

Connects to:
  config.py - reads SCENARIO_PLAYBOOK_DIR
  scenarios/runner.py - calls Playbook.load to start a run
  controllers/scenario_ctrl.py - calls Playbook.list_available
"""

from typing import Any
from pathlib import Path
from dataclasses import dataclass, field

import yaml

from app.config import settings


@dataclass
class PlaybookEvent:
    """
    A single event within a playbook timeline
    """
    delay_seconds: float
    source_type: str
    event_type: str
    source_ip: str | None = None
    dest_ip: str | None = None
    source_port: int | None = None
    dest_port: int | None = None
    hostname: str | None = None
    username: str | None = None
    mitre_tactic: str | None = None
    mitre_technique: str | None = None
    message: str | None = None
    metadata: dict[str, Any] = field(default_factory = dict)
    extra: dict[str, Any] = field(default_factory = dict)


@dataclass
class Playbook:
    """
    A loaded attack scenario with metadata and ordered events
    """
    name: str
    description: str
    mitre_tactics: list[str]
    mitre_techniques: list[str]
    events: list[PlaybookEvent]

    @classmethod
    def load(cls, yaml_path: str | Path) -> Playbook:
        """
        Parse a YAML playbook file into a Playbook instance
        """
        path = Path(yaml_path)
        with path.open() as f:
            data = yaml.safe_load(f)

        events = []
        for ev in data.get("events", []):
            delay = ev.pop("delay_seconds", 0)
            source_type = ev.pop("source_type", "generic")
            event_type = ev.pop("event_type", "")
            events.append(
                PlaybookEvent(
                    delay_seconds = delay,
                    source_type = source_type,
                    event_type = event_type,
                    source_ip = ev.pop("source_ip",
                                       None),
                    dest_ip = ev.pop("dest_ip",
                                     None),
                    source_port = ev.pop("source_port",
                                         None),
                    dest_port = ev.pop("dest_port",
                                       None),
                    hostname = ev.pop("hostname",
                                      None),
                    username = ev.pop("username",
                                      None),
                    mitre_tactic = ev.pop("mitre_tactic",
                                          None),
                    mitre_technique = ev.pop("mitre_technique",
                                             None),
                    message = ev.pop("message",
                                     None),
                    metadata = ev.pop("metadata",
                                      {}),
                    extra = ev,
                )
            )

        return cls(
            name = data.get("name",
                            path.stem),
            description = data.get("description",
                                   ""),
            mitre_tactics = data.get("mitre_tactics",
                                     []),
            mitre_techniques = data.get("mitre_techniques",
                                        []),
            events = events,
        )

    @classmethod
    def list_available(cls) -> list[dict[str, Any]]:
        """
        Scan the playbooks directory and return metadata for each
        """
        playbook_dir = Path(settings.SCENARIO_PLAYBOOK_DIR)
        if not playbook_dir.exists():
            return []

        available = []
        for yml_file in sorted(playbook_dir.glob("*.yml")):
            with yml_file.open() as f:
                data = yaml.safe_load(f)
            available.append(
                {
                    "filename": yml_file.name,
                    "name": data.get("name",
                                     yml_file.stem),
                    "description": data.get("description",
                                            ""),
                    "mitre_tactics": data.get("mitre_tactics",
                                              []),
                    "mitre_techniques": data.get("mitre_techniques",
                                                 []),
                    "event_count": len(data.get("events",
                                                [])),
                }
            )
        return available
