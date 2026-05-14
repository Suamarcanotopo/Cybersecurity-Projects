"""
©AngelaMos | 2026
scenarios.py

Route handlers for the scenarios API (/v1/scenarios)

Mounts GET /available, GET /running, POST /start, POST /<id>/stop,
POST /<id>/pause, POST /<id>/resume, and PUT /<id>/speed.

Connects to:
  controllers/scenario_ctrl.py - business logic
  schemas/scenario.py - ScenarioStartRequest, SpeedRequest
  routes/__init__.py - scenarios_bp registered here
"""

from typing import Any

from flask import Blueprint

from app.controllers import scenario_ctrl
from app.core.decorators import endpoint, S, R
from app.schemas.scenario import ScenarioStartRequest, SpeedRequest


scenarios_bp = Blueprint("scenarios", __name__)


@scenarios_bp.get("/available")
@endpoint()
@R()
def list_available() -> Any:
    """
    Return metadata for all available playbooks
    """
    return scenario_ctrl.list_available()


@scenarios_bp.get("/running")
@endpoint()
@R()
def list_running() -> Any:
    """
    Return all active scenario runs
    """
    return scenario_ctrl.list_running()


@scenarios_bp.post("/start")
@endpoint()
@S(ScenarioStartRequest)
@R(status = 201)
def start_scenario() -> Any:
    """
    Start a new scenario from a playbook file
    """
    return scenario_ctrl.start_scenario()


@scenarios_bp.post("/<run_id>/stop")
@endpoint()
@R()
def stop_scenario(run_id: str) -> Any:
    """
    Stop an active scenario run
    """
    return scenario_ctrl.stop_scenario(run_id)


@scenarios_bp.post("/<run_id>/pause")
@endpoint()
@R()
def pause_scenario(run_id: str) -> Any:
    """
    Pause an active scenario run
    """
    return scenario_ctrl.pause_scenario(run_id)


@scenarios_bp.post("/<run_id>/resume")
@endpoint()
@R()
def resume_scenario(run_id: str) -> Any:
    """
    Resume a paused scenario run
    """
    return scenario_ctrl.resume_scenario(run_id)


@scenarios_bp.put("/<run_id>/speed")
@endpoint()
@S(SpeedRequest)
@R()
def set_speed(run_id: str) -> Any:
    """
    Adjust playback speed of an active scenario
    """
    return scenario_ctrl.set_speed(run_id)
