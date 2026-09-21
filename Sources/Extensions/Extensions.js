// Extension switches and permission revocation remain native operations, not page-side state.
document.addEventListener("change", (event) => {
  const control = event.target.closest("[data-extension-toggle]");
  if (!control) return;
  const target = new URL("aero://extensions/action/toggle");
  target.searchParams.set("id", control.dataset.extensionToggle);
  target.searchParams.set("value", control.checked ? "on" : "off");
  rememberPage();
  location.href = target.href;
});
