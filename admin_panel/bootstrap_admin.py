import argparse
import base64
import hashlib
import os
import secrets
import sqlite3
from datetime import datetime, timezone
from pathlib import Path


BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = Path(os.environ.get("ADMIN_DATA_DIR", BASE_DIR / "data"))
DB_PATH = Path(os.environ.get("ADMIN_DB_PATH", DATA_DIR / "admin.sqlite3"))

def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def connect_db() -> sqlite3.Connection:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    return sqlite3.connect(DB_PATH)


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
              server_url TEXT NOT NULL DEFAULT 'http://103.118.29.243:3000',
              license_key TEXT NOT NULL DEFAULT '',
              device_id TEXT NOT NULL DEFAULT '',
              notes TEXT NOT NULL DEFAULT '',
              password_hash TEXT NOT NULL DEFAULT '',
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
            """
        )
        existing_columns = {
            row[1]
            for row in db.execute("PRAGMA table_info(users)").fetchall()
        }
        if "password_hash" not in existing_columns:
            db.execute("ALTER TABLE users ADD COLUMN password_hash TEXT NOT NULL DEFAULT ''")
        db.commit()


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 210_000)
    return "pbkdf2_sha256$210000$%s$%s" % (
        base64.urlsafe_b64encode(salt).decode("ascii"),
        base64.urlsafe_b64encode(digest).decode("ascii"),
    )


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
    print(f"Database: {DB_PATH}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Create or reset admin account")
    parser.add_argument("--username", required=True)
    parser.add_argument("--password", required=True)
    args = parser.parse_args()
    create_admin(args.username, args.password)


if __name__ == "__main__":
    main()
