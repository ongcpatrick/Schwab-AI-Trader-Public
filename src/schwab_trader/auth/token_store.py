"""Local token persistence."""

import logging
import os
from pathlib import Path

from schwab_trader.auth.models import OAuthToken

logger = logging.getLogger(__name__)


class FileTokenStore:
    """Persist OAuth tokens to a local JSON file."""

    def __init__(self, path: Path) -> None:
        self.path = path

    def load(self) -> OAuthToken | None:
        """Load the stored token, if present."""

        if not self.path.exists():
            return None
        return OAuthToken.model_validate_json(self.path.read_text(encoding="utf-8"))

    def save(self, token: OAuthToken) -> None:
        """Persist the current token and restrict file permissions."""

        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(token.model_dump_json(indent=2), encoding="utf-8")
        try:
            os.chmod(self.path, 0o600)
        except PermissionError:
            pass
        _sync_to_railway(token.model_dump_json())

    def clear(self) -> None:
        """Remove any stored token."""

        if self.path.exists():
            self.path.unlink()


def _sync_to_railway(token_json: str) -> None:
    """Push the fresh token to Railway's SCHWAB_TOKEN_JSON env var via GraphQL API.

    Requires RAILWAY_TOKEN (personal API token from railway.com/account/tokens)
    and RAILWAY_PROJECT_ID / RAILWAY_ENVIRONMENT_ID / RAILWAY_SERVICE_ID, which
    Railway injects automatically into every running service container.
    Only runs when all four env vars are present — no-ops silently otherwise.
    """
    api_token = os.environ.get("RAILWAY_TOKEN", "")
    project_id = os.environ.get("RAILWAY_PROJECT_ID", "")
    environment_id = os.environ.get("RAILWAY_ENVIRONMENT_ID", "")
    service_id = os.environ.get("RAILWAY_SERVICE_ID", "")

    if not all([api_token, project_id, environment_id]):
        return  # not on Railway or token not configured

    import json
    import urllib.request

    query = """
    mutation variableUpsert($input: VariableUpsertInput!) {
      variableUpsert(input: $input)
    }
    """
    variables = {
        "input": {
            "projectId": project_id,
            "environmentId": environment_id,
            "serviceId": service_id or None,
            "name": "SCHWAB_TOKEN_JSON",
            "value": token_json,
        }
    }
    payload = json.dumps({"query": query, "variables": variables}).encode()
    req = urllib.request.Request(
        "https://backboard.railway.com/graphql/v2",
        data=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_token}",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            result = json.loads(resp.read())
            if result.get("errors"):
                logger.warning("Railway token sync error: %s", result["errors"])
            else:
                logger.debug("Railway SCHWAB_TOKEN_JSON synced successfully")
    except Exception as exc:
        logger.warning("Railway token sync failed (non-fatal): %s", exc)
