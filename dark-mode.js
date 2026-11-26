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
      const destination = staffHead || studentThreadHead || null;
      if (destination) {
        button.classList.add("ashiana-theme-inline", "ashiana-theme-chat-inline");
        if (button.parentElement !== destination) destination.appendChild(button);
      } else if (portal && !portal.classList.contains("hidden") && studentHeader) {
        studentHeader.classList.add("ashiana-theme-header");
        button.classList.add("ashiana-theme-inline");
        button.classList.remove("ashiana-theme-chat-inline");
        if (button.parentElement !== studentHeader) studentHeader.appendChild(button);
      } else {
        button.classList.remove("ashiana-theme-inline", "ashiana-theme-chat-inline");
        if (button.parentElement !== document.body) document.body.appendChild(button);
      }
    };
    document.body.appendChild(button);
    placeToggle();
    const studentPortal = document.getElementById("student-portal-view");
    if (studentPortal && window.MutationObserver) {
      new MutationObserver(placeToggle).observe(studentPortal, { attributes: true, attributeFilter: ["class"] });
    }
    if (window.MutationObserver) {
      new MutationObserver(placeToggle).observe(document.body, { childList: true, subtree: true });
    }
    setTheme(root.getAttribute("data-ashiana-theme") || "light");
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", addToggle, { once: true });
  else addToggle();
})();