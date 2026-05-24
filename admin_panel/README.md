# Machine Translate Admin Panel

This admin panel is intentionally separate from the Pipecat/Soniox realtime server.

- Pipecat/Soniox server can continue running on port `3000`.
- Admin panel defaults to port `8080`.
- Admin data is stored in `admin_panel/data/admin.sqlite3`.

## Install

Use the same Python environment already used on the VPS if it has FastAPI and Uvicorn:

```powershell
cd C:\MachinetranslateAI\admin_panel
pip install -r requirements.txt
```

## First Admin Account

Create or reset the admin account:

```powershell
cd C:\MachinetranslateAI\admin_panel
python bootstrap_admin.py --username admin --password "change-this-password"
```

Use a strong password on the VPS.

## Run

```powershell
cd C:\MachinetranslateAI\admin_panel
$env:ADMIN_TOKEN_SECRET="change-this-to-a-long-random-secret"
.\run_admin.ps1
```

Open:

```text
http://YOUR_VPS_IP:8080
```

## Current Scope

The MVP supports:

- Admin login.
- List users.
- Create users.
- Edit users.
- Delete users.
- Manage per-user connect server URL.
- Manage role, status, license key, device ID, and notes.

## Production Notes

Before exposing this publicly:

- Put it behind HTTPS with Caddy, Nginx, or IIS reverse proxy.
- Change `ADMIN_TOKEN_SECRET`.
- Use a strong admin password.
- Restrict port `8080` by firewall if possible.
- Back up `admin_panel/data/admin.sqlite3`.

Future integration with Flutter should call an authenticated endpoint such as:

```text
GET /api/me/config
```

That endpoint can later return the current user's `server_url`, license policy, and feature flags.
