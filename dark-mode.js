(() => {
  "use strict";
  const KEY = "ashiana-attendance-theme";
  const root = document.documentElement;
  const getSaved = () => {
    try { return localStorage.getItem(KEY); } catch (_) { return null; }
  };
  const setTheme = (theme) => {
    const dark = theme === "dark";
    root.setAttribute("data-ashiana-theme", dark ? "dark" : "light");
    try { localStorage.setItem(KEY, dark ? "dark" : "light"); } catch (_) {}
    const button = document.getElementById("ashiana-theme-toggle");
    if (button) {
      button.setAttribute("aria-pressed", dark ? "true" : "false");
      button.setAttribute("aria-label", dark ? "Switch to light mode" : "Switch to dark mode");
      const icon = button.querySelector(".ashiana-theme-icon");
      const label = button.querySelector(".ashiana-theme-label");
      if (icon) icon.textContent = dark ? "☀" : "☾";
      if (label) label.textContent = dark ? "Light" : "Dark";
    }
  };
  const saved = getSaved();
  setTheme(saved === "dark" || saved === "light" ? saved :
    (window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"));
  const addToggle = () => {
    if (!document.body || document.getElementById("ashiana-theme-toggle")) return;
    const button = document.createElement("button");
    button.id = "ashiana-theme-toggle";
    button.type = "button";
    button.innerHTML = '<span class="ashiana-theme-icon" aria-hidden="true"></span><span class="ashiana-theme-label"></span>';
    button.addEventListener("click", () => {
      setTheme(root.getAttribute("data-ashiana-theme") === "dark" ? "light" : "dark");
    });
    const placeToggle = () => {
      const staffModal = document.getElementById("parent-school-messages-modal");
      const staffHead = staffModal?.classList.contains("open") &&
        staffModal.querySelector(".staff-comm-card.thread-open #parent-school-message-thread-head:not(.hidden)");
      const studentPanel = document.getElementById("student-dashboard-panel");
      const studentThreadHead = studentPanel?.classList.contains("student-messages-fullscreen")
        ? studentPanel.querySelector(".family-chat-thread-head") : null;
      const portal = document.getElementById("student-portal-view");
      const studentHeader = portal?.querySelector(":scope > div > div:first-child > div:first-child");
      const adminRoot = document.getElementById("admin-portal-view");
      const adminHeader = adminRoot && !adminRoot.classList.contains("hidden")
        ? adminRoot.querySelector(":scope > .admin-dashboard-compact-header") : null;
      const adminActions = adminHeader?.querySelector(".admin-dashboard-compact-actions");
      const restoreAdminMenuControls = () => {
        const row = document.querySelector("#admin-side-menu .ashiana-admin-menu-utility-row");
        if (!row) return;
        const signOutInRow = row.querySelector(".ashiana-admin-menu-signout-inline");
        const marker = document.querySelector("#admin-side-menu .ashiana-admin-menu-signout-placeholder");
        if (signOutInRow && marker?.parentNode) marker.parentNode.insertBefore(signOutInRow, marker.nextSibling);
        if (button.parentElement === row) document.body.appendChild(button);
        const assistantInRow = row.querySelector(".ashiana-admin-ai-menu");
        if (assistantInRow) {
          assistantInRow.classList.remove("ashiana-admin-ai-menu");
          document.body.appendChild(assistantInRow);
        }
        marker?.remove();
        button.classList.remove("ashiana-theme-admin-menu");
        row.remove();
      };
      const destination = staffHead || studentThreadHead || null;
      if (destination) {
        restoreAdminMenuControls();
        button.classList.add("ashiana-theme-inline", "ashiana-theme-chat-inline");
        if (button.parentElement !== destination) destination.appendChild(button);
      } else if (adminActions) {
        // Keep the dashboard header uncluttered. Put the existing theme and AI
        // controls together immediately beside the Admin menu's Sign Out action.
        button.classList.remove("ashiana-theme-inline", "ashiana-theme-admin-inline", "ashiana-theme-chat-inline");
        button.classList.add("ashiana-theme-admin-menu");
        const assistant = document.querySelector(
          "#ai-assistant-fab, #ashiana-ai-assistant, #ashiana-ai-fab, .ai-assistant-fab, [data-ai-assistant-launcher], button[aria-label*='assistant' i], button[title*='assistant' i]"
        );
        const menu = document.getElementById("admin-side-menu");
        const signOut = menu && [...menu.querySelectorAll("button,a,[role='button']")]
          .find((node) => /^(sign\s*out|log\s*out)$/i.test((node.innerText || node.textContent || "").replace(/\s+/g, " ").trim()));
        if (menu && signOut) {
          let utilityRow = menu.querySelector(":scope .ashiana-admin-menu-utility-row");
          if (!utilityRow) {
            const marker = document.createElement("span");
            marker.className = "ashiana-admin-menu-signout-placeholder";
            marker.hidden = true;
            signOut.insertAdjacentElement("beforebegin", marker);
            utilityRow = document.createElement("div");
            utilityRow.className = "ashiana-admin-menu-utility-row";
            utilityRow.setAttribute("aria-label", "Appearance, assistant and sign out controls");
            marker.insertAdjacentElement("beforebegin", utilityRow);
          }
          if (button.parentElement !== utilityRow) utilityRow.appendChild(button);
          if (assistant && assistant !== button) {
            assistant.classList.remove("ashiana-admin-ai-inline");
            assistant.classList.add("ashiana-admin-ai-menu");
            if (assistant.parentElement !== utilityRow) utilityRow.appendChild(assistant);
          }
          signOut.classList.add("ashiana-admin-menu-signout-inline");
          if (signOut.parentElement !== utilityRow) utilityRow.appendChild(signOut);
        } else {
          button.classList.remove("ashiana-theme-admin-menu");
          if (button.parentElement !== document.body) document.body.appendChild(button);
          if (assistant && assistant !== button && assistant.parentElement !== document.body) document.body.appendChild(assistant);
        }
      } else if (portal && !portal.classList.contains("hidden") && studentHeader) {
        restoreAdminMenuControls();
        const adminAssistant = document.querySelector(".ashiana-admin-ai-inline");
        if (adminAssistant) {
          adminAssistant.classList.remove("ashiana-admin-ai-inline");
          if (adminAssistant.parentElement !== document.body) document.body.appendChild(adminAssistant);
        }
        studentHeader.classList.add("ashiana-theme-header");
        button.classList.add("ashiana-theme-inline");
        button.classList.remove("ashiana-theme-chat-inline", "ashiana-theme-admin-inline");
        if (button.parentElement !== studentHeader) studentHeader.appendChild(button);
      } else {
        restoreAdminMenuControls();
        const adminAssistant = document.querySelector(".ashiana-admin-ai-inline");
        if (adminAssistant) {
          adminAssistant.classList.remove("ashiana-admin-ai-inline");
          if (adminAssistant.parentElement !== document.body) document.body.appendChild(adminAssistant);
        }
        button.classList.remove("ashiana-theme-inline", "ashiana-theme-chat-inline", "ashiana-theme-admin-inline", "ashiana-theme-admin-menu");
        if (button.parentElement !== document.body) document.body.appendChild(button);
      }
    };
    document.body.appendChild(button);
    placeToggle();
    const studentPortal = document.getElementById("student-portal-view");
    if (studentPortal && window.MutationObserver) {
      new MutationObserver(placeToggle).observe(studentPortal, { attributes: true, attributeFilter: ["class"] });
    }
    const adminPortal = document.getElementById("admin-portal-view");
    if (adminPortal && window.MutationObserver) {
      new MutationObserver(placeToggle).observe(adminPortal, { attributes: true, attributeFilter: ["class"] });
    }
    if (window.MutationObserver) {
      new MutationObserver(placeToggle).observe(document.body, { childList: true, subtree: true });
      const staffModal = document.getElementById("parent-school-messages-modal");
      const staffThreadHead = document.getElementById("parent-school-message-thread-head");
      if (staffModal) new MutationObserver(placeToggle).observe(staffModal, { attributes: true, attributeFilter: ["class"] });
      if (staffThreadHead) new MutationObserver(placeToggle).observe(staffThreadHead, { attributes: true, attributeFilter: ["class"] });
      const studentPanel = document.getElementById("student-dashboard-panel");
      if (studentPanel) new MutationObserver(placeToggle).observe(studentPanel, { attributes: true, attributeFilter: ["class"] });
    }
    setTheme(root.getAttribute("data-ashiana-theme") || "light");
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", addToggle, { once: true });
  else addToggle();
})();

/* Modern Admin dashboard enhancement.
   Reuses live KPI DOM and existing Admin menu actions; no demo values or
   replacement attendance logic are introduced. */
(() => {
  "use strict";
  const ROOT_ID = "admin-portal-view";
  const ACTIONS = [
    { label: "Faculty Management", description: "Staff records and assignments", match: /faculty|staff management/i, icon: "♙" },
    { label: "Student Management", description: "Admissions and student records", match: /student management|students/i, icon: "◎" },
    { label: "Attendance Reports", description: "Daily and monthly attendance", match: /attendance.*report|report.*attendance/i, icon: "▤" },
    { label: "Fee Management", description: "Collections and fee status", match: /fee management|fees/i, icon: "₹" }
  ];
  const findMenuAction = (pattern) => {
    const menu = document.getElementById("admin-side-menu");
    if (!menu) return null;
    return [...menu.querySelectorAll("button,[role='button'],a")]
      .find((node) => pattern.test((node.innerText || node.textContent || "").replace(/\s+/g, " ").trim()));
  };
  const getMetricGrid = (root) => [...root.children].find((node) =>
    node.classList?.contains("grid") && node.classList.contains("grid-cols-2"));
  const findMetric = (grid, label) => {
    if (!grid) return null;
    return [...grid.children].find((card) =>
      (card.innerText || "").toLowerCase().includes(label.toLowerCase())) || null;
  };
  const metricValue = (grid, label) => {
    const card = findMetric(grid, label);
    const spans = card?.querySelectorAll("span");
    return spans?.[1]?.textContent?.trim() || "—";
  };
  const greeting = () => {
    const hour = new Date().getHours();
    return hour < 12 ? "Good Morning, Admin" : hour < 17 ? "Good Afternoon, Admin" : "Good Evening, Admin";
  };
  const dateLabel = () => new Intl.DateTimeFormat("en-IN", {
    weekday: "long", day: "numeric", month: "long", year: "numeric"
  }).format(new Date());
  const enhance = () => {
    const root = document.getElementById(ROOT_ID);
    if (!root || root.classList.contains("hidden")) return;
    const grid = getMetricGrid(root);
    if (!grid) return;

    let welcome = root.querySelector(":scope > .ashiana-modern-welcome");
    if (!welcome) {
      welcome = document.createElement("section");
      welcome.className = "ashiana-modern-welcome";
      welcome.innerHTML = '<div class="ashiana-modern-welcome-copy"><span class="ashiana-modern-eyebrow">ASHIANA PUBLIC SCHOOL · ATTENDANCE MANAGEMENT</span><h2></h2><p></p></div><span class="ashiana-modern-live-pill"><i></i> LIVE OVERVIEW</span>';
      const header = root.querySelector(":scope > .admin-dashboard-compact-header");
      if (header) header.insertAdjacentElement("afterend", welcome);
      else root.insertBefore(welcome, grid);
    }
    const heading = welcome.querySelector("h2");
    const date = welcome.querySelector("p");
    if (heading && heading.textContent !== greeting()) heading.textContent = greeting();
    if (date && date.textContent !== dateLabel()) date.textContent = dateLabel();

    let rate = root.querySelector(":scope > .ashiana-modern-rate");
    if (!rate) {
      rate = document.createElement("section");
      rate.className = "ashiana-modern-rate";
      rate.innerHTML = '<div><span class="ashiana-modern-rate-label">Faculty attendance rate</span><strong class="ashiana-modern-rate-value">—</strong></div><div class="ashiana-modern-rate-track"><span></span></div><small>Present today compared with total active faculty</small>';
      grid.insertAdjacentElement("afterend", rate);
    }
    const total = Number.parseFloat(metricValue(grid, "Total Faculty").replace(/[^\d.]/g, ""));
    const present = Number.parseFloat(metricValue(grid, "Present Today").replace(/[^\d.]/g, ""));
    const percentage = Number.isFinite(total) && total > 0 && Number.isFinite(present)
      ? Math.max(0, Math.min(100, present / total * 100)) : null;
    const percentText = percentage === null ? "—" : percentage.toFixed(1) + "%";
    const value = rate.querySelector(".ashiana-modern-rate-value");
    const fill = rate.querySelector(".ashiana-modern-rate-track span");
    if (value && value.textContent !== percentText) value.textContent = percentText;
    if (fill) fill.style.width = percentage === null ? "0%" : percentage + "%";

    let quick = root.querySelector(":scope > .ashiana-modern-quick-actions");
    if (!quick) {
      quick = document.createElement("section");
      quick.className = "ashiana-modern-quick-actions";
      quick.innerHTML = '<div class="ashiana-modern-section-heading"><h3>Quick Actions</h3><span>Frequently used modules</span></div><div class="ashiana-modern-action-grid"></div>';
      rate.insertAdjacentElement("afterend", quick);
    }
    const actionGrid = quick.querySelector(".ashiana-modern-action-grid");
    if (actionGrid && !actionGrid.children.length) {
      ACTIONS.forEach((action) => {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "ashiana-modern-action";
        button.innerHTML = '<span class="ashiana-modern-action-icon" aria-hidden="true"></span><span class="ashiana-modern-action-copy"><strong></strong><small></small></span><span class="ashiana-modern-action-arrow" aria-hidden="true">›</span>';
        button.querySelector(".ashiana-modern-action-icon").textContent = action.icon;
        button.querySelector("strong").textContent = action.label;
        button.querySelector("small").textContent = action.description;
        button.addEventListener("click", () => {
          const target = findMenuAction(action.match);
          if (target) target.click();
          else {
            const menuToggle = document.querySelector('[aria-controls="admin-side-menu"],#admin-menu-toggle');
            menuToggle?.click();
          }
        });
        actionGrid.appendChild(button);
      });
    }
  };

  const start = () => {
    enhance();
    if (window.MutationObserver && document.body) {
      let queued = false;
      const observer = new MutationObserver(() => {
        if (queued) return;
        queued = true;
        requestAnimationFrame(() => { queued = false; enhance(); });
      });
      observer.observe(document.body, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ["class"] });
    }
    window.addEventListener("focus", enhance);
    document.addEventListener("visibilitychange", () => { if (!document.hidden) enhance(); });
    window.setInterval(enhance, 60000);
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start, { once: true });
  else start();
})();


/* Admin dashboard Phase 2: live faculty attendance analytics, roster preview
   and recent activity. Reads existing admin-authorized tables only. */
(() => {
  "use strict";
  const ROOT_ID = "admin-portal-view";
  const STYLE_ID = "ashiana-phase2-dashboard-styles";
  let rangeDays = 7;
  let cached = { staff: [], punches: [], leaves: [], audits: [] };
  let loading = false;
  let lastLoadedAt = 0;
  let observerQueued = false;

  const el = (tag, cls, text) => {
    const node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined && text !== null) node.textContent = String(text);
    return node;
  };
  const indiaDate = (date) => {
    const parts = new Intl.DateTimeFormat("en-CA", {
      timeZone: "Asia/Kolkata", year: "numeric", month: "2-digit", day: "2-digit"
    }).formatToParts(date || new Date());
    const values = {};
    parts.forEach((part) => { values[part.type] = part.value; });
    return values.year + "-" + values.month + "-" + values.day;
  };
  const shiftDate = (value, amount) => {
    const parts = value.split("-").map(Number);
    return new Date(Date.UTC(parts[0], parts[1] - 1, parts[2] + amount)).toISOString().slice(0, 10);
  };
  const formatDate = (value) => {
    if (!value) return "—";
    const date = new Date(value + "T00:00:00+05:30");
    return new Intl.DateTimeFormat("en-IN", { day: "2-digit", month: "short" }).format(date);
  };
  const formatTime = (value) => {
    if (!value) return "—";
    const match = String(value).match(/(?:T|\s)?(\d{1,2}):(\d{2})/);
    if (!match) return String(value);
    const hour = Number(match[1]);
    return String(hour % 12 || 12).padStart(2, "0") + ":" + match[2] + (hour >= 12 ? " PM" : " AM");
  };
  const formatAgo = (value) => {
    const time = new Date(value).getTime();
    if (!Number.isFinite(time)) return "Recent";
    const minutes = Math.max(0, Math.floor((Date.now() - time) / 60000));
    if (minutes < 1) return "Just now";
    if (minutes < 60) return minutes + " min ago";
    const hours = Math.floor(minutes / 60);
    if (hours < 24) return hours + " hr ago";
    return Math.floor(hours / 24) + " day ago";
  };
  const latestByStaff = (punches) => {
    const map = new Map();
    punches.forEach((punch) => {
      const key = String(punch.staff_id || punch.emp_id || punch.staff_name || "");
      if (!key) return;
      const current = map.get(key);
      if (!current || new Date(punch.created_at).getTime() > new Date(current.created_at).getTime()) {
        map.set(key, punch);
      }
    });
    return map;
  };
  const getDashboard = () => document.getElementById(ROOT_ID);
  const ensurePanel = (root) => {
    let panel = root.querySelector(":scope > .ashiana-phase2-panel");
    if (panel) return panel;
    panel = el("section", "ashiana-phase2-panel");
    const heading = el("div", "ashiana-phase2-heading");
    const titleWrap = el("div");
    titleWrap.append(el("h3", "", "Attendance Analytics & Live Activity"));
    titleWrap.append(el("p", "", "Live faculty attendance from the school's attendance records"));
    const controls = el("div", "ashiana-phase2-controls");
    const refresh = el("button", "ashiana-phase2-refresh", "↻ Refresh");
    refresh.type = "button";
    refresh.addEventListener("click", () => loadData(true));
    controls.append(refresh);
    heading.append(titleWrap, controls);
    panel.append(heading);
    const analytics = el("section", "ashiana-phase2-analytics");
    const chartCard = el("div", "ashiana-phase2-card ashiana-phase2-chart-card");
    chartCard.append(el("div", "ashiana-phase2-card-heading"));
    const chartHead = chartCard.querySelector(".ashiana-phase2-card-heading");
    chartHead.append(el("h4", "", "Faculty attendance trend"));
    const ranges = el("div", "ashiana-phase2-range");
    [7, 30].forEach((days) => {
      const button = el("button", "", days + " days");
      button.type = "button";
      button.dataset.days = String(days);
      button.setAttribute("aria-pressed", days === rangeDays ? "true" : "false");
      button.addEventListener("click", () => {
        rangeDays = days;
        panel.querySelectorAll(".ashiana-phase2-range button").forEach((item) => {
          item.setAttribute("aria-pressed", Number(item.dataset.days) === rangeDays ? "true" : "false");
        });
        renderAnalytics(panel);
      });
      ranges.append(button);
    });
    chartHead.append(ranges);
    chartCard.append(el("div", "ashiana-phase2-kpis"));
    chartCard.append(el("div", "ashiana-phase2-chart", "Loading attendance trend…"));
    chartCard.append(el("p", "ashiana-phase2-note", "Counts are based on recorded faculty IN punches; no punch is not automatically treated as an absence."));
    analytics.append(chartCard);
    const activityCard = el("div", "ashiana-phase2-card ashiana-phase2-activity-card");
    activityCard.append(el("div", "ashiana-phase2-card-heading"));
    activityCard.querySelector(".ashiana-phase2-card-heading").append(el("h4", "", "Recent activity"));
    activityCard.append(el("div", "ashiana-phase2-activity-list", "Loading recent activity…"));
    analytics.append(activityCard);
    panel.append(analytics);

    const rosterCard = el("section", "ashiana-phase2-card ashiana-phase2-roster-card");
    const rosterHead = el("div", "ashiana-phase2-card-heading");
    const rosterTitle = el("div");
    rosterTitle.append(el("h4", "", "Faculty live roster"));
    rosterTitle.append(el("p", "", "Today's latest punch status"));
    rosterHead.append(rosterTitle);
    const rosterTools = el("div", "ashiana-phase2-roster-tools");
    const search = el("input", "ashiana-phase2-search");
    search.type = "search";
    search.placeholder = "Search faculty…";
    search.setAttribute("aria-label", "Search faculty live roster");
    search.addEventListener("input", () => renderRoster(panel));
    const openFull = el("button", "ashiana-phase2-open-roster", "Open full roster ↗");
    openFull.type = "button";
    openFull.addEventListener("click", () => {
      const menu = document.getElementById("admin-side-menu");
      const target = menu && [...menu.querySelectorAll("button,a,[role='button']")].find((node) =>
        /live attendance|live faculty/i.test((node.innerText || node.textContent || "").replace(/\s+/g, " ").trim()));
      if (target) target.click();
      else {
        const toggle = document.querySelector('[aria-controls="admin-side-menu"],#admin-menu-toggle');
        if (toggle) toggle.click();
      }
    });
    rosterTools.append(search, openFull);
    rosterHead.append(rosterTools);
    rosterCard.append(rosterHead, el("div", "ashiana-phase2-roster-summary"));
    const tableWrap = el("div", "ashiana-phase2-table-wrap");
    const table = el("table", "ashiana-phase2-table");
    const thead = el("thead");
    const headerRow = el("tr");
    ["Faculty member", "Department", "First IN", "Last punch", "Status"].forEach((label) => headerRow.append(el("th", "", label)));
    thead.append(headerRow);
    table.append(thead, el("tbody"));
    tableWrap.append(table);
    rosterCard.append(tableWrap, el("p", "ashiana-phase2-note", "Roster status reflects the latest recorded punch for today. Work-hour totals remain in the existing Live Attendance report."));
    panel.append(rosterCard);
    const quick = root.querySelector(":scope > .ashiana-modern-quick-actions");
    const rate = root.querySelector(":scope > .ashiana-modern-rate");
    if (quick) quick.insertAdjacentElement("afterend", panel);
    else if (rate) rate.insertAdjacentElement("afterend", panel);
    else root.append(panel);
    return panel;
  };
  const makeKpi = (label, value, tone) => {
    const card = el("div", "ashiana-phase2-kpi " + (tone || ""));
    card.append(el("span", "", label), el("strong", "", value));
    return card;
  };
  const renderAnalytics = (panel) => {
    const today = indiaDate();
    const from = shiftDate(today, -(rangeDays - 1));
    const punches = cached.punches.filter((row) => row.attendance_date >= from && row.attendance_date <= today);
    const todayPunches = punches.filter((row) => row.attendance_date === today);
    const activeStaff = cached.staff.length;
    const todayIn = new Set(todayPunches.filter((row) => row.type === "IN").map((row) => row.staff_id || row.emp_id));
    const latest = latestByStaff(todayPunches);
    const working = [...latest.values()].filter((row) => row.type === "IN").length;
    const approved = cached.leaves.filter((row) => row.status === "APPROVED" && row.from_date <= today && row.to_date >= today).length;
    const pending = cached.leaves.filter((row) => row.status === "PENDING").length;
    const kpis = panel.querySelector(".ashiana-phase2-kpis");
    kpis.replaceChildren(
      makeKpi("Active faculty", activeStaff, ""),
      makeKpi("Recorded IN today", todayIn.size, "green"),
      makeKpi("Working now", working, "blue"),
      makeKpi("On approved leave", approved, "purple"),
      makeKpi("Pending leave requests", pending, "amber")
    );
    const days = [];
    for (let offset = rangeDays - 1; offset >= 0; offset--) {
      const date = shiftDate(today, -offset);
      const present = new Set(punches.filter((row) => row.attendance_date === date && row.type === "IN")
        .map((row) => row.staff_id || row.emp_id)).size;
      days.push({ date, present, percent: activeStaff ? Math.min(100, present / activeStaff * 100) : 0 });
    }
    const chart = panel.querySelector(".ashiana-phase2-chart");
    chart.replaceChildren();
    if (!days.some((day) => day.present > 0)) {
      chart.append(el("p", "ashiana-phase2-empty", "No faculty IN punches recorded in this period yet."));
      return;
    }
    const chartGrid = el("div", "ashiana-phase2-bars");
    const chartDays = rangeDays === 7 ? days : days.reduce((groups, day, index) => {
      const groupIndex = Math.floor(index / 7);
      if (!groups[groupIndex]) groups[groupIndex] = { start: day.date, end: day.date, total: 0, count: 0 };
      groups[groupIndex].end = day.date;
      groups[groupIndex].total += day.present;
      groups[groupIndex].count += 1;
      return groups;
    }, []).map((group) => ({
      date: group.start,
      label: formatDate(group.start) + "–" + formatDate(group.end),
      present: Math.round(group.total / group.count),
      percent: activeStaff ? Math.min(100, group.total / group.count / activeStaff * 100) : 0
    }));
    chartDays.forEach((day) => {
      const column = el("div", "ashiana-phase2-bar-column");
      const value = el("strong", "", String(day.present));
      const track = el("div", "ashiana-phase2-bar-track");
      const bar = el("span", "ashiana-phase2-bar");
      bar.style.height = Math.max(day.present ? 4 : 0, day.percent) + "%";
      track.append(bar);
      column.append(value, track, el("small", "", day.label || formatDate(day.date)));
      column.title = day.date + ": average " + day.present + " faculty with an IN punch per day";
      chartGrid.append(column);
    });
    chart.append(chartGrid);
  };
  const renderRoster = (panel) => {
    const today = indiaDate();
    const todays = cached.punches.filter((row) => row.attendance_date === today)
      .sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
    const firstIn = new Map();
    todays.forEach((row) => {
      const key = String(row.staff_id || row.emp_id || "");
      if (row.type === "IN" && key && !firstIn.has(key)) firstIn.set(key, row);
    });
    const latest = latestByStaff(todays);
    const search = (panel.querySelector(".ashiana-phase2-search")?.value || "").trim().toLowerCase();
    const rows = cached.staff.map((staff) => {
      const key = String(staff.id || "");
      const last = latest.get(key);
      const first = firstIn.get(key);
      const onLeave = cached.leaves.some((leave) => leave.status === "APPROVED" && String(leave.staff_id || "") === key && leave.from_date <= today && leave.to_date >= today);
      return { staff, last, first, status: onLeave ? "On leave" : !last ? "Not marked" : last.type === "IN" ? "Working" : "Checked out" };
    }).filter((row) => !search || [row.staff.name, row.staff.emp_id, row.staff.department].some((value) => String(value || "").toLowerCase().includes(search)))
      .sort((a, b) => {
        const order = { Working: 0, "On leave": 1, "Not marked": 2, "Checked out": 3 };
        return order[a.status] - order[b.status] || String(a.staff.name).localeCompare(String(b.staff.name));
      }).slice(0, 12);
    const summary = panel.querySelector(".ashiana-phase2-roster-summary");
    const working = cached.staff.filter((staff) => latest.get(String(staff.id || ""))?.type === "IN").length;
    const marked = new Set(todays.filter((row) => row.type === "IN").map((row) => row.staff_id)).size;
    summary.replaceChildren(
      el("span", "", cached.staff.length + " active faculty"),
      el("span", "", marked + " with IN today"),
      el("span", "", working + " currently working")
    );
    const tbody = panel.querySelector(".ashiana-phase2-table tbody");
    tbody.replaceChildren();
    if (!rows.length) {
      const tr = el("tr");
      const td = el("td", "ashiana-phase2-empty", search ? "No faculty match this search." : "No active faculty records found.");
      td.colSpan = 5;
      tr.append(td);
      tbody.append(tr);
      return;
    }
    rows.forEach(({ staff, last, first, status }) => {
      const tr = el("tr");
      tr.append(el("td", "ashiana-phase2-name", staff.name || "—"));
      tr.append(el("td", "", staff.department || "—"));
      tr.append(el("td", "", first ? formatTime(first.timestamp) : "—"));
      tr.append(el("td", "", last ? formatTime(last.timestamp) : "—"));
      const statusCell = el("td");
      statusCell.append(el("span", "ashiana-phase2-status " + (status === "Working" ? "is-working" : status === "Checked out" ? "is-done" : status === "On leave" ? "is-leave" : "is-muted"), status));
      tr.append(statusCell);
      tbody.append(tr);
    });
  };
  const renderActivity = (panel) => {
    const items = [];
    cached.punches.forEach((row) => {
      items.push({ at: row.created_at, title: (row.staff_name || "Faculty") + " · PUNCH " + row.type, detail: (row.emp_id || "Staff") + " · " + row.attendance_date, kind: "punch" });
    });
    cached.leaves.forEach((row) => {
      items.push({ at: row.created_at, title: (row.staff_name || "Faculty") + " · Leave " + String(row.status || "submitted").toLowerCase(), detail: (row.type || "Leave") + " · " + row.from_date + " to " + row.to_date, kind: "leave" });
    });
    cached.audits.forEach((row) => {
      items.push({ at: row.timestamp, title: String(row.action || "Activity").replace(/_/g, " "), detail: [row.entity, row.actor].filter(Boolean).join(" · "), kind: "audit" });
    });
    items.sort((a, b) => new Date(b.at).getTime() - new Date(a.at).getTime());
    const list = panel.querySelector(".ashiana-phase2-activity-list");
    list.replaceChildren();
    if (!items.length) {
      list.append(el("p", "ashiana-phase2-empty", "No recent attendance, leave or audit activity is available."));
      return;
    }
    items.slice(0, 8).forEach((item) => {
      const row = el("div", "ashiana-phase2-activity-item");
      row.append(el("span", "ashiana-phase2-activity-dot " + item.kind));
      const copy = el("div", "ashiana-phase2-activity-copy");
      copy.append(el("strong", "", item.title), el("small", "", item.detail || "—"));
      row.append(copy, el("time", "", formatAgo(item.at)));
      list.append(row);
    });
  };
  const loadData = async (force) => {
    const root = getDashboard();
    if (!root || root.classList.contains("hidden") || loading) return;
    const panel = ensurePanel(root);
    if (!force && Date.now() - lastLoadedAt < 60000 && cached.staff.length) return;
    if (typeof window.__ashianaGetMainSupabaseClient !== "function" && !window.__ashianaMainSupabaseClient) {
      panel.querySelector(".ashiana-phase2-chart").textContent = "Waiting for the authenticated school connection…";
      return;
    }
    loading = true;
    const refresh = panel.querySelector(".ashiana-phase2-refresh");
    if (refresh) { refresh.disabled = true; refresh.textContent = "Loading…"; }
    try {
      const supa = window.__ashianaMainSupabaseClient || await window.__ashianaGetMainSupabaseClient();
      const userResult = await supa.auth.getUser();
      if (userResult.error || !userResult.data?.user) throw new Error("Administrator session is not available.");
      const today = indiaDate();
      const from = shiftDate(today, -29);
      const results = await Promise.all([
        supa.from("staff").select("id,emp_id,name,department,status").eq("status", "ACTIVE").order("name").limit(250),
        supa.from("attendance_punches").select("id,staff_id,staff_name,emp_id,attendance_date,type,timestamp,created_at").gte("attendance_date", from).lte("attendance_date", today).order("created_at", { ascending: false }).limit(3000),
        supa.from("leave_requests").select("id,staff_id,staff_name,type,from_date,to_date,status,created_at").order("created_at", { ascending: false }).limit(50),
        supa.from("audit_logs").select("id,timestamp,actor,action,entity").order("timestamp", { ascending: false }).limit(30)
      ]);
      const failed = results.find((result) => result.error);
      if (failed) throw failed.error;
      cached = {
        staff: results[0].data || [],
        punches: results[1].data || [],
        leaves: results[2].data || [],
        audits: results[3].data || []
      };
      lastLoadedAt = Date.now();
      renderAnalytics(panel);
      renderRoster(panel);
      renderActivity(panel);
      const heading = panel.querySelector(".ashiana-phase2-heading p");
      if (heading) heading.textContent = "Live school records · Updated " + new Date().toLocaleTimeString("en-IN", { hour: "2-digit", minute: "2-digit" });
    } catch (error) {
      const chart = panel.querySelector(".ashiana-phase2-chart");
      if (chart) chart.textContent = "Attendance analytics could not be loaded. Check the administrator connection and try Refresh.";
      const activity = panel.querySelector(".ashiana-phase2-activity-list");
      if (activity) activity.textContent = "Recent activity is temporarily unavailable.";
      console.warn("[Ashiana Phase 2 dashboard]", error?.message || error);
    } finally {
      loading = false;
      if (refresh) { refresh.disabled = false; refresh.textContent = "↻ Refresh"; }
    }
  };
  const schedule = () => {
    if (observerQueued) return;
    observerQueued = true;
    requestAnimationFrame(() => {
      observerQueued = false;
      const root = getDashboard();
      if (root && !root.classList.contains("hidden")) loadData(false);
    });
  };
  const start = () => {
    const root = getDashboard();
    if (root && window.MutationObserver) {
      new MutationObserver(schedule).observe(root, { attributes: true, attributeFilter: ["class"] });
      new MutationObserver(schedule).observe(document.body, { childList: true, subtree: true });
    }
    schedule();
    window.addEventListener("focus", () => loadData(false));
    document.addEventListener("visibilitychange", () => { if (!document.hidden) loadData(false); });
    window.setInterval(() => loadData(false), 60000);
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start, { once: true });
  else start();
})();
