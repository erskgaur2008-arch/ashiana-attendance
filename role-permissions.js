(() => {
  "use strict";

  const TABLE = "role_portal_module_permissions";
  const DEFAULTS = {
    STAFF: {
      punch: true, history: true, students: false, communication: true,
      leave: true, profile: true, biometric: true, fees: true
    },
    TEACHER: {
      punch: true, history: true, students: true, communication: true,
      leave: true, profile: true, biometric: true, fees: true
    },
    STUDENT: {
      profile: true, mentor: true, classmates: true, notice: true,
      attendance: true, "report-card": true, fees: true, homework: true,
      timetable: true, leave: true, calendar: true, "id-card": true,
      "event-photos": true, messages: true
    }
  };
  const MODULES = {
    STAFF: [
      ["punch", "Punch & attendance"], ["history", "Attendance history"],
      ["students", "Student attendance", "Teacher designation required"],
      ["communication", "Staff communication"], ["leave", "Leave requests"],
      ["profile", "Staff profile"], ["biometric", "Biometric settings"],
      ["fees", "Fee confirmations", "Existing Principal authorization is still required"]
    ],
    TEACHER: [
      ["punch", "Punch & attendance"], ["history", "Attendance history"],
      ["students", "Student attendance"], ["communication", "Staff communication"],
      ["leave", "Leave requests"], ["profile", "Staff profile"],
      ["biometric", "Biometric settings"],
      ["fees", "Fee confirmations", "Existing Principal authorization is still required"]
    ],
    STUDENT: [
      ["profile", "Profile"], ["mentor", "Your mentor"],
      ["classmates", "Classmates"], ["notice", "Notices"],
      ["messages", "Family messages", "Parents and guardians can contact an assigned teacher, Principal, or School Administration."],
      ["attendance", "Attendance"], ["report-card", "Report card"],
      ["fees", "Fees management"], ["homework", "Homework"],
      ["timetable", "Timetable"], ["leave", "Leave requests"],
      ["calendar", "School calendar"], ["id-card", "ID card"],
      ["event-photos", "Event photos (view only)", "Students can browse published school event galleries."]
    ]
  };
  const ROLE_LABELS = { STAFF: "Staff", TEACHER: "Teacher", STUDENT: "Student" };

  let activeRole = "";
  let activeIdentity = "";
  let activePermissions = {};
  let activeReady = false;
  let activeLoad = null;
  let adminClient = null;
  let adminUser = null;
  let adminPermissions = {};
  let selectedAdminRole = "TEACHER";

  function cloneDefaults(role) {
    return { ...(DEFAULTS[role] || {}) };
  }

  function eventPermissionsChanged() {
    window.dispatchEvent(new CustomEvent("ashiana-role-permissions-updated", {
      detail: { role: activeRole, ready: activeReady }
    }));
  }

  function canOpen(moduleKey) {
    if (!activeRole || activeRole === "ADMIN") return true;
    if (!activeReady) return false;
    if (activeRole === "STAFF" && moduleKey === "students") return false;
    return Object.prototype.hasOwnProperty.call(activePermissions, moduleKey)
      ? activePermissions[moduleKey] === true
      : cloneDefaults(activeRole)[moduleKey] === true;
  }

  function isReady() {
    return !activeRole || activeRole === "ADMIN" || activeReady;
  }

  function mergeRows(role, rows) {
    const merged = cloneDefaults(role);
    for (const row of Array.isArray(rows) ? rows : []) {
      if (row && typeof row.module_key === "string" &&
          Object.prototype.hasOwnProperty.call(merged, row.module_key)) {
        merged[row.module_key] = row.enabled === true;
      }
    }
    if (role === "STAFF") merged.students = false;
    return merged;
  }

  async function readStudentToken() {
    try {
      const nativeToken = await window.AshianaNative?.getStudentSessionToken?.();
      if (nativeToken) return String(nativeToken);
    } catch (_) {}
    try {
      return String(sessionStorage.getItem("aps_student_session_token_v1") ||
        localStorage.getItem("aps_student_session_token_v1") || "");
    } catch (_) {
      return "";
    }
  }

  async function loadForUser({ client, user, role, studentToken } = {}) {
    const normalizedRole = String(role || user?.type || "").toUpperCase();
    if (normalizedRole === "ADMIN") {
      activeRole = "ADMIN";
      activeIdentity = "ADMIN";
      activePermissions = {};
      activeReady = true;
      eventPermissionsChanged();
      return;
    }
    if (!Object.prototype.hasOwnProperty.call(DEFAULTS, normalizedRole)) return;

    const identity = normalizedRole === "STUDENT"
      ? String(user?.studentRecord?.id || user?.studentRecord?.enroll_no || "student")
      : String(user?.staffRecord?.id || user?.staffRecord?.email || user?.email || "staff");
    const loadKey = `${normalizedRole}:${identity}`;
    if (activeIdentity === loadKey && activeReady) return;
    if (activeIdentity === loadKey && activeLoad) return activeLoad;

    activeRole = normalizedRole;
    activeIdentity = loadKey;
    activePermissions = {};
    activeReady = false;
    eventPermissionsChanged();

    activeLoad = (async () => {
      let permissions = cloneDefaults(normalizedRole);
      try {
        if (!client) throw new Error("The portal data connection is unavailable.");
        if (normalizedRole === "STUDENT") {
          const token = String(studentToken || await readStudentToken());
          if (!/^[a-f0-9]{64}$/i.test(token)) throw new Error("Student session is unavailable.");
          const { data, error } = await client.rpc("student_role_portal_permissions", { p_token: token });
          if (error) throw error;
          if (!data?.success || !data?.permissions) throw new Error("Student permissions could not be loaded.");
          permissions = { ...permissions, ...data.permissions };
        } else {
          const { data, error } = await client.from(TABLE)
            .select("module_key,enabled")
            .eq("role", normalizedRole);
          if (error) throw error;
          permissions = mergeRows(normalizedRole, data);
        }
      } catch (error) {
        console.warn("Role module permissions could not be loaded; using existing role defaults.", error?.message || error);
        if (normalizedRole === "STAFF") permissions.students = false;
      }

      if (activeIdentity !== loadKey) return;
      activePermissions = permissions;
      activeReady = true;
      activeLoad = null;
      eventPermissionsChanged();
    })();
    return activeLoad;
  }

  function setStatus(message, isError = false) {
    const status = document.getElementById("role-permission-status");
    if (!status) return;
    status.textContent = message;
    status.classList.toggle("text-rose-600", isError);
    status.classList.toggle("text-emerald-700", !isError);
  }

  function selectedRoleRows() {
    const role = selectedAdminRole;
    const inputs = [...document.querySelectorAll("[data-role-permission-key]")];
    return inputs.map(input => ({
      role,
      module_key: input.dataset.rolePermissionKey,
      enabled: role === "STAFF" && input.dataset.rolePermissionKey === "students"
        ? false
        : input.checked,
      updated_by: String(adminUser?.username || adminUser?.email || "ADMIN"),
      updated_at: new Date().toISOString()
    }));
  }

  function renderRolePermissions() {
    const select = document.getElementById("role-permission-role");
    const list = document.getElementById("role-permission-list");
    if (!select || !list) return;
    selectedAdminRole = select.value in MODULES ? select.value : "TEACHER";
    const role = selectedAdminRole;
    const current = { ...cloneDefaults(role), ...(adminPermissions[role] || {}) };
    if (role === "STAFF") current.students = false;
    list.innerHTML = MODULES[role].map(([key, label, note]) => {
      const locked = role === "STAFF" && key === "students";
      const checked = current[key] === true;
      const showNote = locked || (role === "STUDENT" && key === "event-photos");
      const lockNote = showNote && note ? `<span class="block text-[11px] text-slate-500">${note}</span>` : "";
      return `<label class="flex items-center justify-between gap-4 rounded-xl border border-slate-200 bg-white px-4 py-3 ${locked ? "opacity-70" : "cursor-pointer"}">
        <span class="min-w-0"><strong class="block text-sm text-slate-800">${label}</strong>${lockNote}</span>
        <input type="checkbox" class="h-5 w-5 shrink-0 accent-emerald-700" data-role-permission-key="${key}" ${checked ? "checked" : ""} ${locked ? "disabled" : ""} aria-label="Allow ${label} for ${ROLE_LABELS[role]}">
      </label>`;
    }).join("");
    list.querySelectorAll("[data-role-permission-key]").forEach(input => {
      input.addEventListener("change", () => setStatus("Unsaved changes"));
    });
    setStatus("Changes apply the next time a user signs in.");
  }

  async function loadAdminPanel(client, user) {
    const list = document.getElementById("role-permission-list");
    if (!list) return;
    adminClient = client || null;
    adminUser = user || null;
    if (String(user?.type || "").toUpperCase() !== "ADMIN") {
      setStatus("Administrator access is required.", true);
      return;
    }
    list.innerHTML = '<p class="text-sm text-slate-500">Loading role permissions…</p>';
    try {
      if (!adminClient) throw new Error("The portal data connection is unavailable.");
      const { data, error } = await adminClient.from(TABLE).select("role,module_key,enabled");
      if (error) throw error;
      adminPermissions = {};
      for (const role of Object.keys(MODULES)) adminPermissions[role] = cloneDefaults(role);
      for (const row of Array.isArray(data) ? data : []) {
        if (adminPermissions[row.role] && Object.prototype.hasOwnProperty.call(adminPermissions[row.role], row.module_key)) {
          adminPermissions[row.role][row.module_key] = row.enabled === true;
        }
      }
      renderRolePermissions();
    } catch (error) {
      list.innerHTML = '<p class="text-sm text-rose-600">Could not load saved permissions. Please retry.</p>';
      setStatus(String(error?.message || error), true);
    }
  }

  async function saveSelectedRole() {
    if (String(adminUser?.type || "").toUpperCase() !== "ADMIN" || !adminClient) {
      setStatus("Administrator access is required.", true);
      return;
    }
    const rows = selectedRoleRows();
    if (!rows.some(row => row.enabled)) {
      setStatus("Keep at least one module enabled for this role.", true);
      return;
    }
    const button = document.getElementById("role-permission-save");
    if (button) button.disabled = true;
    setStatus("Saving…");
    try {
      const { error } = await adminClient.from(TABLE).upsert(rows, { onConflict: "role,module_key" });
      if (error) throw error;
      adminPermissions[selectedAdminRole] = Object.fromEntries(rows.map(row => [row.module_key, row.enabled]));
      if (activeRole === selectedAdminRole) {
        activePermissions = { ...cloneDefaults(activeRole), ...adminPermissions[selectedAdminRole] };
        activeReady = true;
        eventPermissionsChanged();
      }
      setStatus(`${ROLE_LABELS[selectedAdminRole]} permissions saved.`);
    } catch (error) {
      setStatus(`Save failed: ${error?.message || error}`, true);
    } finally {
      if (button) button.disabled = false;
    }
  }

  function restoreSelectedRoleDefaults() {
    if (!Object.prototype.hasOwnProperty.call(DEFAULTS, selectedAdminRole)) return;
    adminPermissions[selectedAdminRole] = cloneDefaults(selectedAdminRole);
    renderRolePermissions();
    setStatus("Defaults restored in this form. Save to apply them.");
  }

  document.addEventListener("change", event => {
    if (event.target?.id === "role-permission-role") renderRolePermissions();
  });

  window.AshianaRolePermissions = {
    loadForUser,
    canOpen,
    isReady,
    loadAdminPanel,
    saveSelectedRole,
    restoreSelectedRoleDefaults
  };
})();
