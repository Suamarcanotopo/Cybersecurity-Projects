"""
©AngelaMos | 2026
__init__.py

Blueprint registration for the Flask application

register_blueprints mounts all seven route blueprints under the /v1
API prefix. Called by the application factory during startup.

Key exports:
  register_blueprints - registers all route blueprints on the Flask app
"""

from flask import Flask


API_PREFIX = "/v1"


def register_blueprints(app: Flask) -> None:
    """
    Register all route blueprints under the API version
    """
    from app.routes.auth import auth_bp
    from app.routes.admin import admin_bp
    from app.routes.dashboard import dashboard_bp
    from app.routes.logs import logs_bp
    from app.routes.alerts import alerts_bp
    from app.routes.rules import rules_bp
    from app.routes.scenarios import scenarios_bp

    app.register_blueprint(auth_bp, url_prefix = f"{API_PREFIX}/auth")
    app.register_blueprint(admin_bp, url_prefix = f"{API_PREFIX}/admin")
    app.register_blueprint(dashboard_bp, url_prefix = f"{API_PREFIX}/dashboard")
    app.register_blueprint(logs_bp, url_prefix = f"{API_PREFIX}/logs")
    app.register_blueprint(alerts_bp, url_prefix = f"{API_PREFIX}/alerts")
    app.register_blueprint(rules_bp, url_prefix = f"{API_PREFIX}/rules")
    app.register_blueprint(scenarios_bp, url_prefix = f"{API_PREFIX}/scenarios")
