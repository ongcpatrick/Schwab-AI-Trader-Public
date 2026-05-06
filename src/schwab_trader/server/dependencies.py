"""Dependency providers for FastAPI routes."""

from typing import Annotated

from fastapi import Cookie, Header, HTTPException, status

from schwab_trader.auth.browser_session import COOKIE_NAME, is_valid_session
from schwab_trader.auth.oauth import OAuthConfig
from schwab_trader.auth.service import SchwabOAuthService
from schwab_trader.auth.session_store import OAuthSessionStore, oauth_session_store
from schwab_trader.auth.token_store import FileTokenStore
from schwab_trader.broker.service import SchwabBrokerService
from schwab_trader.core.settings import get_settings
from schwab_trader.journal.store import SQLiteJournalStore


def get_token_store() -> FileTokenStore:
    """Return the configured local token store."""

    settings = get_settings()
    return FileTokenStore(settings.schwab_token_path)


def get_oauth_service() -> SchwabOAuthService:
    """Return the configured OAuth service."""

    settings = get_settings()
    if (
        not settings.schwab_app_key
        or not settings.schwab_app_secret
        or not settings.schwab_callback_url
    ):
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Schwab OAuth settings are incomplete.",
        )

    config = OAuthConfig(
        client_id=settings.schwab_app_key,
        client_secret=settings.schwab_app_secret,
        redirect_uri=settings.schwab_callback_url,
        scope=settings.schwab_scope,
    )
    return SchwabOAuthService(config=config)


def get_oauth_session_store() -> OAuthSessionStore:
    """Return the shared in-memory OAuth session store."""

    return oauth_session_store


def get_broker_service() -> SchwabBrokerService:
    """Return the broker orchestration service."""

    token_store = get_token_store()
    oauth_service = get_oauth_service()
    return SchwabBrokerService(token_store=token_store, oauth_service=oauth_service)


def get_journal_store() -> SQLiteJournalStore:
    """Return the configured local journal store."""

    settings = get_settings()
    return SQLiteJournalStore.from_database_url(settings.journal_database_url)


def require_auth(
    session: Annotated[str | None, Cookie(alias=COOKIE_NAME)] = None,
    x_api_key: Annotated[str | None, Header()] = None,
) -> None:
    """Gate private routes with dual-mode authentication.

    Browser access: valid HTTP-only session cookie set by POST /login.
    Server-to-server: SCHWAB_TRADER_OPERATOR_API_KEY in X-API-Key header.

    The API key is never sent to the browser — it stays server-side only.
    If neither credential is configured the app fails closed (503).
    """
    settings = get_settings()

    # ── server-to-server path (cloud routines / scripts) ──────────────
    if x_api_key is not None:
        expected = settings.operator_api_key
        if not expected:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="SCHWAB_TRADER_OPERATOR_API_KEY is not configured.",
            )
        if x_api_key == expected:
            return
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid operator API key.",
        )

    # ── browser session cookie path ────────────────────────────────────
    if session and is_valid_session(session):
        return

    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Authentication required. Visit /login.",
    )


# Keep the old name so existing imports don't break during the transition.
require_operator_key = require_auth
