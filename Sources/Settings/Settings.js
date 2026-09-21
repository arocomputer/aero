// Convert ordinary form changes into the local actions validated by Tab's navigation delegate.
function changeSetting(control) {
  const value =
    control.type === "checkbox"
      ? control.checked
        ? "on"
        : "off"
      : control.value;
  const target = new URL(`aero://settings/action/${control.dataset.setting}`);
  target.searchParams.set("value", value);
  rememberPage();
  location.href = target.href;
}
document.addEventListener("change", (event) => {
  if (event.target.matches("[data-setting]")) changeSetting(event.target);
  if (event.target.matches("[data-site-policy]")) {
    const target = new URL("aero://settings/action/site-policy");
    target.searchParams.set("feature", event.target.dataset.sitePolicy);
    if (event.target.dataset.origin)
      target.searchParams.set("origin", event.target.dataset.origin);
    target.searchParams.set("value", event.target.value);
    rememberPage();
    location.href = target.href;
  }
  if (event.target.matches("[data-privacy-setting]")) {
    const target = new URL("aero://settings/action/privacy-setting");
    target.searchParams.set("key", event.target.dataset.privacySetting);
    target.searchParams.set("value", event.target.checked ? "on" : "off");
    rememberPage();
    location.href = target.href;
  }
});

// Data deletion uses the selected time range; the native side confirms the exact operation.
document.addEventListener("click", (event) => {
  const button = event.target.closest("[data-clear]");
  if (!button) return;
  const range = document.querySelector("#clear-range").value;
  rememberPage();
  location.href = `aero://settings/action/${button.dataset.clear}?value=${encodeURIComponent(range)}`;
});
