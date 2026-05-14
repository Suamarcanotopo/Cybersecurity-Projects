"""
©AngelaMos | 2026
scenario_ctrl.py

Business logic for scenario management

Thin coordinator between the scenarios API and the runner/playbook
layer. Delegates to ScenarioRunner for start, stop, pause, resume,
and speed changes, and to Playbook.list_available for the catalog.

Key exports:
  list_available, list_running, start_scenario, stop_scenario,
  pause_scenario, resume_scenario, set_speed

Connects to:
  models/ScenarioRun.py - get_active_runs, get_by_id
  scenarios/playbook.py - calls list_available
  scenarios/runner.py - calls ScenarioRunner methods
  routes/scenarios.py - called from route handlers
"""

from typing import Any

from flask import g

from app.models.ScenarioRun import ScenarioRun
from app.scenarios.playbook import Playbook
from app.scenarios.runner import ScenarioRunner


def list_available() -> list[dict[str, Any]]:
    """
    Return metadata for all available playbook files
    """
    return Playbook.list_available()


def list_running() -> list[Any]:
    """
    Return all active scenario runs
    """
    return ScenarioRun.get_active_runs()


def start_scenario() -> ScenarioRun:
    """
    Load a playbook and start a new scenario thread
    """
    data = g.validated
    return ScenarioRunner.start(data.filename)


def stop_scenario(run_id: str) -> ScenarioRun:
    """
    Stop an active scenario run
    """
    run = ScenarioRun.get_by_id(run_id)
    ScenarioRunner.stop(str(run.id))
    run.reload()  # type: ignore[no-untyped-call]
    return run


def pause_scenario(run_id: str) -> ScenarioRun:
    """
    Pause an active scenario run
    """
    run = ScenarioRun.get_by_id(run_id)
    ScenarioRunner.pause(str(run.id))
    run.reload()  # type: ignore[no-untyped-call]
    return run


def resume_scenario(run_id: str) -> ScenarioRun:
    """
    Resume a paused scenario run
    """
    run = ScenarioRun.get_by_id(run_id)
    ScenarioRunner.resume(str(run.id))
    run.reload()  # type: ignore[no-untyped-call]
    return run


def set_speed(run_id: str) -> ScenarioRun:
    """
    Adjust the playback speed of an active scenario
    """
    data = g.validated
    run = ScenarioRun.get_by_id(run_id)
    ScenarioRunner.set_speed(str(run.id), data.speed)
    run.reload()  # type: ignore[no-untyped-call]
    return run
