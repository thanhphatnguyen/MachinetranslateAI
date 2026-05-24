import argparse
import base64
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field


BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = Path(os.environ.get("ADMIN_DATA_DIR", BASE_DIR / "data"))
DB_PATH = Path(os.environ.get("ADMIN_DB_PATH", DATA_DIR / "admin.sqlite3"))
STATIC_DIR = BASE_DIR / "static"
TOKEN_TTL_HOURS = int(os.environ.get("ADMIN_TOKEN_TTL_HOURS", "12"))
TOKEN_SECRET = os.environ.get("ADMIN_TOKEN_SECRET", "change-this-admin-secret")


app = FastAPI(title="Machine Translate Admin", docs_url="/api/docs", redoc_url=None)
app.add_middleware(
    CORSMiddleware,
    allow_origins=os.environ.get("ADMIN_CORS_ORIGINS", "*").split(","),
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


class LoginRequest(BaseModel):
    username: str
    password: str


class UserIn(BaseModel):
    email: str = Field(default="", max_length=255)
    display_name: str = Field(default="", max_length=255)
    role: str = Field(default="user", pattern="^(user|admin)$")
    status: str = Field(default="active", pattern="^(active|disabled)$")
    server_url: str = Field(default="", max_length=500)
    license_key: str = Field(default="", max_length=120)
    device_id: str = Field(default="", max_length=255)
    notes: str = Field(default="", max_length=2000)


class UserUpdate(UserIn):
    pass


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def connect_db() -> sqlite3.Connection:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db() -> None:
    with connect_db() as db:
        db.execute(
            """
            CREATE TABLE IF NOT EXISTS admins (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              username TEXT NOT NULL UNIQUE,
              password_hash TEXT NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
            """
        )
        db.execute(
            """
            CREATE TABLE IF NOT EXISTS users (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              email TEXT NOT NULL UNIQUE,
              display_name TEXT NOT NULL DEFAULT '',
              role TEXT NOT NULL DEFAULT 'user',
              status TEXT NOT NULL DEFAULT 'active',
              server_url TEXT NOT NULL DEFAULT '',
              license_key TEXT NOT NULL DEFAULT '',
              device_id TEXT NOT NULL DEFAULT '',
              notes TEXT NOT NULL DEFAULT '',
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
            """
        )
        db.commit()


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 210_000)
    return "pbkdf2_sha256$210000$%s$%s" % (
        base64.urlsafe_b64encode(salt).decode("ascii"),
        base64.urlsafe_b64encode(digest).decode("ascii"),
    )


def verify_password(password: str, password_hash: str) -> bool:
    try:
        algo, rounds, salt_b64, digest_b64 = password_hash.split("$", 3)
        if algo != "pbkdf2_sha256":
            return False
        salt = base64.urlsafe_b64decode(salt_b64.encode("ascii"))
        expected = base64.urlsafe_b64decode(digest_b64.encode("ascii"))
        actual = hashlib.pbkdf2_hmac(
            "sha256", password.encode("utf-8"), salt, int(rounds)
        )
        return hmac.compare_digest(actual, expected)
    except Exception:
        return False


def b64_json(data: dict[str, Any]) -> str:
    raw = json.dumps(data, separators=(",", ":"), sort_keys=True).encode("utf-8")
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def unb64_json(data: str) -> dict[str, Any]:
    padded = data + "=" * (-len(data) % 4)
    raw = base64.urlsafe_b64decode(padded.encode("ascii"))
    return json.loads(raw.decode("utf-8"))


def sign_token(payload: dict[str, Any]) -> str:
    body = b64_json(payload)
    sig = hmac.new(TOKEN_SECRET.encode("utf-8"), body.encode("ascii"), hashlib.sha256)
    return f"{body}.{base64.urlsafe_b64encode(sig.digest()).decode('ascii').rstrip('=')}"


def verify_token(token: str) -> dict[str, Any]:
    try:
        body, signature = token.split(".", 1)
        expected = hmac.new(
            TOKEN_SECRET.encode("utf-8"), body.encode("ascii"), hashlib.sha256
        ).digest()
        actual = base64.urlsafe_b64decode((signature + "=" * (-len(signature) % 4)).encode("ascii"))
        if not hmac.compare_digest(actual, expected):
            raise ValueError("bad signature")
        payload = unb64_json(body)
        if int(payload.get("exp", 0)) < int(datetime.now(timezone.utc).timestamp()):
            raise ValueError("expired token")
        return payload
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid or expired token")


def require_admin(authorization: str | None = Header(default=None)) -> dict[str, Any]:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token")
    return verify_token(authorization.removeprefix("Bearer ").strip())


def row_to_dict(row: sqlite3.Row) -> dict[str, Any]:
    return {key: row[key] for key in row.keys()}


@app.on_event("startup")
def startup() -> None:
    init_db()


@app.get("/")
def index() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


@app.post("/api/auth/login")
def login(payload: LoginRequest) -> dict[str, Any]:
    with connect_db() as db:
        admin = db.execute(
            "SELECT * FROM admins WHERE username = ?", (payload.username.strip(),)
        ).fetchone()
    if not admin or not verify_password(payload.password, admin["password_hash"]):
        raise HTTPException(status_code=401, detail="Invalid username or password")

    exp = datetime.now(timezone.utc) + timedelta(hours=TOKEN_TTL_HOURS)
    token = sign_token(
        {
            "sub": str(admin["id"]),
            "username": admin["username"],
            "role": "admin",
            "exp": int(exp.timestamp()),
        }
    )
    return {"token": token, "username": admin["username"], "expires_at": exp.isoformat()}


@app.get("/api/me")
def me(admin: dict[str, Any] = Depends(require_admin)) -> dict[str, Any]:
    return {"username": admin["username"], "role": admin["role"]}


@app.get("/api/users")
def list_users(
    q: str = "",
    status: str = "",
    admin: dict[str, Any] = Depends(require_admin),
) -> dict[str, Any]:
    del admin
    clauses = []
    args: list[Any] = []
    if q.strip():
        clauses.append("(email LIKE ? OR display_name LIKE ? OR license_key LIKE ?)")
        needle = f"%{q.strip()}%"
        args.extend([needle, needle, needle])
    if status.strip():
        clauses.append("status = ?")
        args.append(status.strip())
    where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    with connect_db() as db:
        rows = db.execute(
            f"SELECT * FROM users {where} ORDER BY updated_at DESC, id DESC", args
        ).fetchall()
    return {"users": [row_to_dict(row) for row in rows]}


@app.post("/api/users")
def create_user(payload: UserIn, admin: dict[str, Any] = Depends(require_admin)) -> dict[str, Any]:
    del admin
    now = utc_now()
    try:
        with connect_db() as db:
            cur = db.execute(
                """
                INSERT INTO users (
                  email, display_name, role, status, server_url, license_key,
                  device_id, notes, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    payload.email.strip().lower(),
                    payload.display_name.strip(),
                    payload.role,
                    payload.status,
                    payload.server_url.strip(),
                    payload.license_key.strip(),
                    payload.device_id.strip(),
                    payload.notes.strip(),
                    now,
                    now,
                ),
            )
            db.commit()
            row = db.execute("SELECT * FROM users WHERE id = ?", (cur.lastrowid,)).fetchone()
    except sqlite3.IntegrityError:
        raise HTTPException(status_code=409, detail="Email already exists")
    return {"user": row_to_dict(row)}


@app.put("/api/users/{user_id}")
def update_user(
    user_id: int,
    payload: UserUpdate,
    admin: dict[str, Any] = Depends(require_admin),
) -> dict[str, Any]:
    del admin
    now = utc_now()
    try:
        with connect_db() as db:
            cur = db.execute(
                """
                UPDATE users
                   SET email = ?, display_name = ?, role = ?, status = ?,
                       server_url = ?, license_key = ?, device_id = ?,
                       notes = ?, updated_at = ?
                 WHERE id = ?
                """,
                (
                    payload.email.strip().lower(),
                    payload.display_name.strip(),
                    payload.role,
                    payload.status,
                    payload.server_url.strip(),
                    payload.license_key.strip(),
                    payload.device_id.strip(),
                    payload.notes.strip(),
                    now,
                    user_id,
                ),
            )
            if cur.rowcount == 0:
                raise HTTPException(status_code=404, detail="User not found")
            db.commit()
            row = db.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
    except sqlite3.IntegrityError:
        raise HTTPException(status_code=409, detail="Email already exists")
    return {"user": row_to_dict(row)}


@app.delete("/api/users/{user_id}")
def delete_user(user_id: int, admin: dict[str, Any] = Depends(require_admin)) -> dict[str, Any]:
    del admin
    with connect_db() as db:
        cur = db.execute("DELETE FROM users WHERE id = ?", (user_id,))
        db.commit()
    if cur.rowcount == 0:
        raise HTTPException(status_code=404, detail="User not found")
    return {"ok": True}


def create_admin(username: str, password: str) -> None:
    init_db()
    now = utc_now()
    with connect_db() as db:
        db.execute(
            """
            INSERT INTO admins (username, password_hash, created_at, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(username) DO UPDATE SET
              password_hash = excluded.password_hash,
              updated_at = excluded.updated_at
            """,
            (username.strip(), hash_password(password), now, now),
        )
        db.commit()
    print(f"Admin account ready: {username}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Machine Translate admin panel")
    sub = parser.add_subparsers(dest="command", required=True)

    create = sub.add_parser("create-admin")
    create.add_argument("--username", required=True)
    create.add_argument("--password", required=True)

    serve = sub.add_parser("serve")
    serve.add_argument("--host", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=8080)

    args = parser.parse_args()
    if args.command == "create-admin":
        create_admin(args.username, args.password)
    elif args.command == "serve":
        import uvicorn

        init_db()
        uvicorn.run("admin_api:app", host=args.host, port=args.port, reload=False)


if __name__ == "__main__":
    main()
