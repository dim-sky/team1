import os
from dataclasses import dataclass, field
from functools import lru_cache

import jwt
from dotenv import load_dotenv
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jwt import PyJWKClient

load_dotenv()

# auto_error=False: χειριζόμαστε εμείς το "λείπει το token" για να δώσουμε καθαρό μήνυμα
_bearer = HTTPBearer(auto_error=False)


@dataclass
class User:
    """Ο συνδεδεμένος χρήστης, όπως προκύπτει από το token."""
    oid: str                      # μοναδικό id του χρήστη στο Entra
    name: str | None
    username: str | None          # συνήθως το email
    claims: dict = field(repr=False)


@dataclass(frozen=True)
class _Settings:
    tenant_id: str
    api_client_id: str
    required_scope: str

    @property
    def issuer(self) -> str:
        return f"https://login.microsoftonline.com/{self.tenant_id}/v2.0"

    @property
    def jwks_url(self) -> str:
        return f"https://login.microsoftonline.com/{self.tenant_id}/discovery/v2.0/keys"


@lru_cache
def _settings() -> _Settings:
    tenant_id = "b1732512-60e5-48fb-92e8-8d6902ac1349"
    api_client_id = "fb46f4fe-fdab-471f-bd80-daf2e4b5a75e"
    if not tenant_id or not api_client_id:
        raise RuntimeError("Λείπουν τα AZURE_TENANT_ID ή AZURE_API_CLIENT_ID από το .env")
    return _Settings(
        tenant_id=tenant_id,
        api_client_id=api_client_id,
        required_scope=os.getenv("AZURE_API_SCOPE", "access_as_user").strip(),
    )


@lru_cache
def _jwks_client() -> PyJWKClient:
    # Κατεβάζει και κρατάει στη μνήμη τα δημόσια κλειδιά της Microsoft
    return PyJWKClient(_settings().jwks_url, cache_keys=True, lifespan=3600)


def _unauthorized(detail: str) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail=detail,
        headers={"WWW-Authenticate": "Bearer"},
    )


def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
) -> User:
    """FastAPI dependency: επιστρέφει τον χρήστη ή απαντά 401/403."""
    if credentials is None or not credentials.credentials:
        raise _unauthorized("Λείπει το access token.")

    token = credentials.credentials
    cfg = _settings()

    # 1. Βρίσκουμε το σωστό δημόσιο κλειδί της Microsoft για αυτό το token
    try:
        signing_key = _jwks_client().get_signing_key_from_jwt(token)
    except jwt.PyJWKClientConnectionError:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Δεν ήταν δυνατή η επικοινωνία με το Entra ID.",
        )
    except jwt.PyJWKClientError:
        raise _unauthorized("Μη έγκυρο token (άγνωστο κλειδί υπογραφής).")
    except jwt.InvalidTokenError:
        raise _unauthorized("Μη έγκυρο token.")

    # 2. Ελέγχουμε υπογραφή, λήξη, εκδότη (iss) και παραλήπτη (aud)
    try:
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=[cfg.api_client_id, f"api://{cfg.api_client_id}"],
            issuer=cfg.issuer,
            options={"require": ["exp", "iss", "aud"]},
            leeway=60,  # ανοχή 60 δευτερολέπτων σε διαφορές ρολογιού
        )
    except jwt.ExpiredSignatureError:
        raise _unauthorized("Το token έχει λήξει.")
    except jwt.InvalidIssuerError:
        raise _unauthorized(
            "Λάθος εκδότης token. Έλεγξε ότι το manifest του API έχει "
            "requestedAccessTokenVersion = 2."
        )
    except jwt.InvalidAudienceError:
        raise _unauthorized("Το token δεν προορίζεται για αυτό το API.")
    except jwt.InvalidTokenError:
        raise _unauthorized("Μη έγκυρο token.")

    # 3. Ελέγχουμε ότι το token δίνει το δικαίωμα (scope) του API μας
    scopes = claims.get("scp", "").split()
    if cfg.required_scope not in scopes:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=f"Το token δεν έχει το scope '{cfg.required_scope}'.",
        )

    return User(
        oid=claims.get("oid", ""),
        name=claims.get("name"),
        username=claims.get("preferred_username"),
        claims=claims,
    )