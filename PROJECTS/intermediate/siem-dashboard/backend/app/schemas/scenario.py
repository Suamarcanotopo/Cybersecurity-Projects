"""
©AngelaMos | 2026
scenario.py

Pydantic schemas for scenario control endpoints

Two schemas: one to identify a playbook file to start and one to
set a speed multiplier within the configured min/max range.

Key exports:
  ScenarioStartRequest - playbook filename for starting a run
  SpeedRequest - playback speed multiplier

Connects to:
  config.py - reads SCENARIO_MIN_SPEED, SCENARIO_MAX_SPEED
  routes/scenarios.py - passed to S()
"""

from pydantic import BaseModel, Field

from app.config import settings


class ScenarioStartRequest(BaseModel):
    """
    Request to start a scenario playbook by filename
    """
    filename: str = Field(min_length = 1)


class SpeedRequest(BaseModel):
    """
    Request to adjust scenario playback speed
    """
    speed: float = Field(
        ge = settings.SCENARIO_MIN_SPEED,
        le = settings.SCENARIO_MAX_SPEED,
    )
