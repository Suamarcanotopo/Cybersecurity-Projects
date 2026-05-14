"""
©AngelaMos | 2026
ScenarioRun.py

MongoEngine model for tracking scenario playback runs

Records each scenario execution with status, speed, event count,
and timestamps. Provides lifecycle methods (mark_completed,
mark_stopped, mark_paused, mark_resumed, mark_error) and an atomic
increment_events counter updated from the playback thread.

Key exports:
  ScenarioRun - scenario run document with lifecycle methods
  RunStatus - StrEnum of possible run states

Connects to:
  models/Base.py - extends BaseDocument
  scenarios/runner.py - calls lifecycle methods during playback
  controllers/scenario_ctrl.py - start, stop, pause, resume operations
  __init__.py - marks orphaned runs as stopped at startup
"""

from typing import Any
from datetime import datetime, UTC
from enum import StrEnum

from mongoengine import (
    StringField,
    DateTimeField,
    IntField,
    FloatField,
)

from app.models.Base import BaseDocument


class RunStatus(StrEnum):
    """
    Possible states for a scenario run
    """
    RUNNING = "running"
    COMPLETED = "completed"
    STOPPED = "stopped"
    PAUSED = "paused"
    ERROR = "error"


DEFAULT_SPEED = 1.0


class ScenarioRun(BaseDocument):
    """
    Tracks a scenario execution with status and event count
    """
    meta: dict[str, Any] = {  # noqa: RUF012
        "collection": "scenario_runs",
        "ordering": ["-started_at"],
    }

    scenario_name = StringField(required = True)
    status = StringField(
        required = True,
        default = RunStatus.RUNNING,
        choices = [s.value for s in RunStatus],
    )
    started_at = DateTimeField(
        default = lambda: datetime.now(UTC),
    )
    completed_at = DateTimeField()
    events_generated = IntField(default = 0)
    speed = FloatField(default = DEFAULT_SPEED)
    error_message = StringField()

    @classmethod
    def start_run(cls, scenario_name: str) -> ScenarioRun:
        """
        Create a new running scenario record
        """
        run = cls(scenario_name = scenario_name)
        run.save()  # type: ignore[no-untyped-call]
        return run

    @classmethod
    def get_active_runs(cls) -> list[Any]:
        """
        Return all runs with running or paused status
        """
        return list(cls.objects(status__in = [  # type: ignore[no-untyped-call]
            RunStatus.RUNNING,
            RunStatus.PAUSED,
        ]))

    def increment_events(self, count: int = 1) -> None:
        """
        Atomically increment the generated event counter
        """
        self.update(inc__events_generated = count)  # type: ignore[no-untyped-call]
        self.reload()  # type: ignore[no-untyped-call]

    def mark_completed(self) -> None:
        """
        Set status to completed with a timestamp
        """
        self.status = RunStatus.COMPLETED
        self.completed_at = datetime.now(UTC)
        self.save()  # type: ignore[no-untyped-call]

    def mark_stopped(self) -> None:
        """
        Set status to stopped with a timestamp
        """
        self.status = RunStatus.STOPPED
        self.completed_at = datetime.now(UTC)
        self.save()  # type: ignore[no-untyped-call]

    def mark_paused(self) -> None:
        """
        Set status to paused
        """
        self.status = RunStatus.PAUSED
        self.save()  # type: ignore[no-untyped-call]

    def mark_resumed(self) -> None:
        """
        Set status back to running from paused
        """
        self.status = RunStatus.RUNNING
        self.save()  # type: ignore[no-untyped-call]

    def mark_error(self, message: str) -> None:
        """
        Set status to error with a message
        """
        self.status = RunStatus.ERROR
        self.error_message = message
        self.completed_at = datetime.now(UTC)
        self.save()  # type: ignore[no-untyped-call]

    def set_speed(self, speed: float) -> None:
        """
        Update the playback speed multiplier
        """
        self.speed = speed
        self.save()  # type: ignore[no-untyped-call]
