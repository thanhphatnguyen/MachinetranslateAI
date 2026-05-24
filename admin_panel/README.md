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

Health check from the phone/browser:

```text
http://YOUR_VPS_IP:8080/api/health
```

The Flutter login/register screen uses this admin API URL internally:

```text
http://103.118.29.243:8080
```

This is separate from the Pipecat/Soniox realtime connect server URL.
New app registrations and new admin-created users default their connect server URL to:

```text
http://103.118.29.243:3000
```

Admins can override that per user from `Connect server URL`.
New app registrations and new admin-created users default their Soniox API key to:

```text
8dfa5a83f387ffadf2ce3b0d04c90d88b61c077c9e40fefcb1084bfaa39264c2
```

Admins can override that per user from `Soniox API Key`.

If the health check times out:

```powershell
cd C:\MachinetranslateAI\admin_panel
.\check_admin_api.ps1
```

If local health works but the phone/browser still times out, open Windows Firewall from an elevated PowerShell:

```powershell
cd C:\MachinetranslateAI\admin_panel
.\open_admin_firewall_8080.ps1
```

Also allow inbound TCP `8080` in the VPS provider firewall/security group if the provider has one.

## Current Scope

The MVP supports:

- Admin login.
- List users.
- Create users.
- Edit users.
- Delete users.
- Set or reset app user passwords.
- Manage per-user connect server URL.
- Manage per-user Soniox API key.
- Manage role, status, device ID, and notes.
- App email/password register and login through `/api/app/register` and `/api/app/login`.
- App config loading through `/api/app/me/config`.

## Production Notes

Before exposing this publicly:

- Put it behind HTTPS with Caddy, Nginx, or IIS reverse proxy.
- Change `ADMIN_TOKEN_SECRET`.
- Use a strong admin password.
- Restrict port `8080` by firewall if possible.
- Back up `admin_panel/data/admin.sqlite3`.

Flutter calls the authenticated user config endpoint:

```text
GET /api/app/me/config
```

That endpoint returns the current user's `server_url`, Soniox API key, device ID, and account status.
