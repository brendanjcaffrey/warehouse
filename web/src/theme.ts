// the initial data-bs-theme is set by an inline script in index.html before first paint;
// this keeps it in sync when the os preference changes at runtime
export function watchColorMode() {
  const mql = window.matchMedia("(prefers-color-scheme: dark)");
  mql.addEventListener("change", (e) => {
    document.documentElement.setAttribute(
      "data-bs-theme",
      e.matches ? "dark" : "light"
    );
  });
}
