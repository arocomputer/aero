// Search the local store, including records beyond the current result page.
document
  .querySelector("#library-search")
  .addEventListener("keydown", (event) => {
    if (event.key !== "Enter") return;
    const target = new URL(location.href);
    target.searchParams.set("query", event.target.value);
    location.href = target.href;
  });

// Keep transfer progress current without interrupting a search or text selection.
if (location.host === "downloads") {
  setInterval(() => {
    if (
      document.activeElement?.id !== "library-search" &&
      !getSelection()?.toString()
    )
      location.reload();
  }, 3000);
}
