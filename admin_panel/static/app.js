const state = {
  token: localStorage.getItem("admin_token") || "",
  users: [],
  refreshTimer: null,
};

const DEFAULT_CONNECT_SERVER_URL = "http://103.118.29.243:3000";

const $ = (id) => document.getElementById(id);

function authHeaders() {
  return {
    "Content-Type": "application/json",
    Authorization: `Bearer ${state.token}`,
  };
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: {
      ...(options.headers || {}),
      ...(state.token ? authHeaders() : { "Content-Type": "application/json" }),
    },
  });

  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(body.detail || "Request failed");
  }
  return body;
}

function showApp(isAuthed) {
  $("loginView").classList.toggle("hidden", isAuthed);
  $("adminView").classList.toggle("hidden", !isAuthed);
  if (isAuthed) {
    startAutoRefresh();
  } else {
    stopAutoRefresh();
  }
}

function showNotice(message, isError = false) {
  $("toast").textContent = message;
  $("toast").classList.toggle("error-text", isError);
  if (!message) return;
  clearTimeout(window.noticeTimer);
  window.noticeTimer = setTimeout(() => {
    $("toast").textContent = "";
    $("toast").classList.remove("error-text");
  }, 3500);
}

function startAutoRefresh() {
  if (state.refreshTimer) return;
  state.refreshTimer = setInterval(() => {
    loadUsers(false).catch(() => {});
  }, 5000);
}

function stopAutoRefresh() {
  if (!state.refreshTimer) return;
  clearInterval(state.refreshTimer);
  state.refreshTimer = null;
}

function userPayload() {
  return {
    email: $("email").value.trim(),
    password: $("password").value,
    display_name: $("displayName").value.trim(),
    role: $("role").value,
    status: $("status").value,
    server_url: $("serverUrl").value.trim() || DEFAULT_CONNECT_SERVER_URL,
    license_key: $("licenseKey").value.trim(),
    device_id: $("deviceId").value.trim(),
    notes: $("notes").value.trim(),
  };
}

function fillForm(user = null) {
  $("userId").value = user?.id || "";
  $("email").value = user?.email || "";
  $("password").value = "";
  $("displayName").value = user?.display_name || "";
  $("role").value = user?.role || "user";
  $("status").value = user?.status || "active";
  $("serverUrl").value = user?.server_url || DEFAULT_CONNECT_SERVER_URL;
  $("licenseKey").value = user?.license_key || "";
  $("deviceId").value = user?.device_id || "";
  $("notes").value = user?.notes || "";
  $("formError").textContent = "";
  $("deleteBtn").classList.toggle("hidden", !user);
  $("dialogTitle").textContent = user ? "Edit user" : "New user";
}

function openDialog(user = null) {
  fillForm(user);
  $("userDialog").showModal();
}

function closeDialog() {
  $("userDialog").close();
}

function escapeHtml(value) {
  return String(value || "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function renderUsers() {
  const rows = state.users.map((user) => {
    const statusClass = user.status === "active" ? "active" : "disabled";
    return `
      <tr>
        <td>${escapeHtml(user.email)}</td>
        <td>${escapeHtml(user.display_name)}</td>
        <td><span class="pill">${escapeHtml(user.role)}</span></td>
        <td><span class="pill ${statusClass}">${escapeHtml(user.status)}</span></td>
        <td class="url-cell">${escapeHtml(user.server_url)}</td>
        <td>${escapeHtml(user.license_key)}</td>
        <td><button class="secondary" type="button" data-edit="${user.id}">Edit</button></td>
      </tr>
    `;
  });

  $("usersTable").innerHTML =
    rows.join("") ||
    `<tr><td colspan="7" class="muted">No users found.</td></tr>`;

  document.querySelectorAll("[data-edit]").forEach((button) => {
    button.addEventListener("click", () => {
      const user = state.users.find((item) => String(item.id) === button.dataset.edit);
      openDialog(user);
    });
  });
}

async function loadUsers(showErrors = true) {
  const params = new URLSearchParams();
  if ($("searchInput").value.trim()) params.set("q", $("searchInput").value.trim());
  if ($("statusFilter").value) params.set("status", $("statusFilter").value);
  try {
    const data = await api(`/api/users?${params.toString()}`);
    state.users = data.users || [];
    renderUsers();
  } catch (error) {
    if (showErrors) showNotice(error.message, true);
    throw error;
  }
}

async function restoreSession() {
  if (!state.token) {
    showApp(false);
    return;
  }
  try {
    const me = await api("/api/me");
    $("sessionInfo").textContent = `Signed in as ${me.username}`;
    showApp(true);
    await loadUsers();
  } catch (_) {
    localStorage.removeItem("admin_token");
    state.token = "";
    showApp(false);
  }
}

$("loginForm").addEventListener("submit", async (event) => {
  event.preventDefault();
  $("loginError").textContent = "";
  try {
    const data = await api("/api/auth/login", {
      method: "POST",
      body: JSON.stringify({
        username: $("loginUsername").value.trim(),
        password: $("loginPassword").value,
      }),
    });
    state.token = data.token;
    localStorage.setItem("admin_token", state.token);
    $("sessionInfo").textContent = `Signed in as ${data.username}`;
    showApp(true);
    await loadUsers();
  } catch (error) {
    $("loginError").textContent = error.message;
  }
});

$("logoutBtn").addEventListener("click", () => {
  localStorage.removeItem("admin_token");
  state.token = "";
  state.users = [];
  showApp(false);
});

$("newUserBtn").addEventListener("click", () => openDialog());
$("closeDialogBtn").addEventListener("click", closeDialog);
$("cancelBtn").addEventListener("click", closeDialog);
$("refreshBtn").addEventListener("click", loadUsers);
$("statusFilter").addEventListener("change", loadUsers);
$("searchInput").addEventListener("input", () => {
  clearTimeout(window.searchTimer);
  window.searchTimer = setTimeout(loadUsers, 250);
});

$("userForm").addEventListener("submit", async (event) => {
  event.preventDefault();
  $("formError").textContent = "";
  const id = $("userId").value;
  try {
    if (id) {
      await api(`/api/users/${id}`, {
        method: "PUT",
        body: JSON.stringify(userPayload()),
      });
    } else {
      await api("/api/users", {
        method: "POST",
        body: JSON.stringify(userPayload()),
      });
    }
    closeDialog();
    await loadUsers();
    showNotice(id ? "User updated." : "User created.");
  } catch (error) {
    $("formError").textContent = error.message;
  }
});

$("deleteBtn").addEventListener("click", async () => {
  const id = $("userId").value;
  if (!id) return;
  if (!confirm("Delete this user record?")) return;
  try {
    await api(`/api/users/${id}`, { method: "DELETE" });
    closeDialog();
    await loadUsers();
    showNotice("User deleted.");
  } catch (error) {
    $("formError").textContent = error.message;
  }
});

restoreSession();
