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
      const destination = staffHead || studentThreadHead || null;
      if (destination) {
        button.classList.add("ashiana-theme-inline", "ashiana-theme-chat-inline");
        if (button.parentElement !== destination) destination.appendChild(button);
      } else if (adminActions) {
        button.classList.add("ashiana-theme-inline", "ashiana-theme-admin-inline");
        button.classList.remove("ashiana-theme-chat-inline");
        const logo = adminActions.querySelector(".admin-dashboard-compact-logo");
        if (button.parentElement !== adminActions) adminActions.insertBefore(button, logo || null);
        const assistant = document.querySelector(
          "#ai-assistant-fab, #ashiana-ai-assistant, #ashiana-ai-fab, .ai-assistant-fab, [data-ai-assistant-launcher], button[aria-label*='assistant' i], button[title*='assistant' i]"
        );
        if (assistant && assistant !== button) {
          assistant.classList.add("ashiana-admin-ai-inline");
          if (assistant.parentElement !== adminActions) adminActions.insertBefore(assistant, logo || null);
        }
      } else if (portal && !portal.classList.contains("hidden") && studentHeader) {
        studentHeader.classList.add("ashiana-theme-header");
        button.classList.add("ashiana-theme-inline");
        button.classList.remove("ashiana-theme-chat-inline", "ashiana-theme-admin-inline");
        if (button.parentElement !== studentHeader) studentHeader.appendChild(button);
      } else {
        button.classList.remove("ashiana-theme-inline", "ashiana-theme-chat-inline", "ashiana-theme-admin-inline");
        if (button.parentElement !== document.body) document.body.appendChild(button);
        const assistant = document.querySelector(".ashiana-admin-ai-inline");
        assistant?.classList.remove("ashiana-admin-ai-inline");
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
