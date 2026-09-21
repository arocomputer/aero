// Shared navigation and search. Filtering is immediate; focus stays in the search field.
const panels = [...document.querySelectorAll("[data-panel-content]")];
const navigation = [...document.querySelectorAll("[data-panel-link]")];
const search = document.querySelector("#page-search");
const emptySearch = document.querySelector("#empty-search");

function updatePage() {
  const query = search.value.trim().toLocaleLowerCase();
  const selected = panels.some((panel) => panel.id === location.hash.slice(1))
    ? location.hash.slice(1)
    : panels[0].id;
  let total = 0;
  document.body.classList.toggle("searching", Boolean(query));

  for (const panel of panels) {
    const categoryMatch =
      Boolean(query) &&
      (panel.querySelector("h1")?.textContent || "")
        .toLocaleLowerCase()
        .includes(query);
    // Extension discovery stays opt-in, even while searching installed extensions.
    const eligible =
      !panel.hasAttribute("data-discovery") || selected === panel.id;
    let matches = 0;
    for (const row of panel.querySelectorAll("[data-search-row]")) {
      const text =
        `${row.dataset.keywords || ""} ${row.textContent}`.toLocaleLowerCase();
      const match = !query || categoryMatch || text.includes(query);
      row.hidden = !match;
      if (query && match) {
        if (row.matches("details")) row.open = true;
        for (const details of row.querySelectorAll("details"))
          details.open = true;
      }
      if (match) matches++;
    }
    for (const group of panel.querySelectorAll(".group")) {
      const rows = [...group.querySelectorAll("[data-search-row]")];
      group.hidden =
        Boolean(query) && rows.length > 0 && rows.every((row) => row.hidden);
    }
    if (categoryMatch) matches = Math.max(matches, 1);
    panel.hidden = query ? !eligible || matches === 0 : panel.id !== selected;
    if (!panel.hidden) total += matches;
    if (!panel.hidden) {
      for (const image of panel.querySelectorAll("img[data-src]")) {
        image.src = image.dataset.src;
        delete image.dataset.src;
      }
    }
  }
  for (const link of navigation) {
    const section =
      selected.startsWith("privacy-") || selected === "websites"
        ? "privacy"
        : selected === "search-engines"
          ? "search"
          : selected;
    const target = link.closest(".sidebar") ? section : selected;
    if (!query && link.hash === `#${target}`)
      link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  }
  emptySearch.hidden = !query || total > 0;
}

// Preserve the section and search text across a native preference change and page reload.
function rememberPage() {
  try {
    sessionStorage.setItem("settings-search", search.value);
    sessionStorage.setItem("page-scroll", String(scrollY));
    const open = [
      ...document.querySelectorAll("details[open][data-detail]"),
    ].map((item) => item.dataset.detail);
    sessionStorage.setItem("open-details", JSON.stringify(open));
  } catch {}
}
for (const link of navigation) {
  link.addEventListener("click", () => {
    search.value = "";
    scrollTo(0, 0);
    rememberPage();
    requestAnimationFrame(() => {
      updatePage();
      scrollTo(0, 0);
    });
  });
}
try {
  search.value = sessionStorage.getItem("settings-search") || "";
  const open = JSON.parse(sessionStorage.getItem("open-details") || "[]");
  for (const details of document.querySelectorAll("details[data-detail]")) {
    details.open = Array.isArray(open) && open.includes(details.dataset.detail);
  }
} catch {}
document.addEventListener("toggle", rememberPage, true);
search.addEventListener("input", () => {
  rememberPage();
  updatePage();
});
document.addEventListener("click", (event) => {
  if (event.target.closest('a[href^="aero://"]')) rememberPage();
});
addEventListener("hashchange", () => {
  updatePage();
  scrollTo(0, 0);
});
updatePage();
requestAnimationFrame(() => {
  try {
    scrollTo(0, Number(sessionStorage.getItem("page-scroll")) || 0);
  } catch {}
});
