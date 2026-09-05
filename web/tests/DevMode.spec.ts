import { beforeEach, expect, test } from "vitest";
import { applyDevChrome, topBarClassName } from "../src/DevMode";

function productionDocument(): Document {
  const doc = document.implementation.createHTMLDocument("Warehouse");
  doc.head.innerHTML = `
    <title>Warehouse</title>
    <link rel="apple-touch-icon" sizes="180x180" href="/favicon/apple-touch-icon.png" />
    <link rel="icon" type="image/svg+xml" href="/favicon/favicon.svg" />
    <link rel="icon" type="image/png" sizes="32x32" href="/favicon/favicon-32x32.png" />
    <link rel="icon" type="image/png" sizes="16x16" href="/favicon/favicon-16x16.png" />
    <link rel="manifest" href="/site.webmanifest" />
  `;
  return doc;
}

let doc: Document;

beforeEach(() => {
  doc = productionDocument();
});

test("the top bar is tinted only in dev mode", () => {
  expect(topBarClassName(true)).toContain("bg-danger-subtle");
  expect(topBarClassName(false)).not.toContain("bg-danger-subtle");
});

test("the top bar keeps its layout classes in both modes", () => {
  for (const dev of [true, false]) {
    const classes = topBarClassName(dev);
    expect(classes).toContain("d-flex");
    expect(classes).toContain("flex-shrink-0");
    expect(classes).toContain("border-bottom");
  }
});

test("dev chrome leaves only the dev favicon", () => {
  applyDevChrome(doc);
  const icons = [...doc.querySelectorAll('link[rel~="icon"]')].map((l) =>
    l.getAttribute("href")
  );
  expect(icons).toEqual(["/favicon/favicon-dev.svg"]);
  expect(doc.querySelector('link[rel="apple-touch-icon"]')).toBeNull();
});

test("dev chrome keeps unrelated links", () => {
  applyDevChrome(doc);
  expect(doc.querySelector('link[rel="manifest"]')).not.toBeNull();
});

test("dev chrome marks the title", () => {
  applyDevChrome(doc);
  expect(doc.title).toBe("Warehouse (development)");
});

test("dev chrome is idempotent", () => {
  applyDevChrome(doc);
  applyDevChrome(doc);
  expect(doc.querySelectorAll('link[rel~="icon"]')).toHaveLength(1);
  expect(doc.title).toBe("Warehouse (development)");
});
