// vite sets DEV on the dev server and leaves it false in production builds
export function isDevMode(): boolean {
  return import.meta.env.DEV;
}

const DEV_FAVICON = "/favicon/favicon-dev.svg";
const DEV_TITLE_SUFFIX = " (development)";

// tints the top bar so a dev tab is obvious
export function topBarClassName(dev: boolean): string {
  const base = "d-flex flex-shrink-0 border-bottom";
  return dev ? `${base} border-danger bg-danger-subtle` : base;
}

// swaps in the dev favicon and marks the title so a dev tab stands out
// in the tab strip
export function applyDevChrome(doc: Document) {
  doc
    .querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"]')
    .forEach((link) => link.remove());

  const link = doc.createElement("link");
  link.rel = "icon";
  link.type = "image/svg+xml";
  link.href = DEV_FAVICON;
  doc.head.appendChild(link);

  if (!doc.title.endsWith(DEV_TITLE_SUFFIX)) {
    doc.title = `${doc.title}${DEV_TITLE_SUFFIX}`;
  }
}
