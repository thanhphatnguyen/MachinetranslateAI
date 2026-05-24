$ErrorActionPreference = "Stop"

$env:ADMIN_TOKEN_SECRET = if ($env:ADMIN_TOKEN_SECRET) {
  $env:ADMIN_TOKEN_SECRET
} else {
  "replace-this-with-a-long-random-secret-before-public-use"
}

python admin_api.py serve --host 0.0.0.0 --port 8080
