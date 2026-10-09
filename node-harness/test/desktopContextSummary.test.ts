import assert from "node:assert/strict";
import test from "node:test";
import { summarizeSnapshot } from "../src/agent/agentRunner.js";
import { compactSnapshotSummary } from "../src/agent/desktopTools.js";
import type { DesktopContextSnapshot } from "../src/hostClient.js";

const snapshot: DesktopContextSnapshot = {
  id: "ctx-desktop",
  capturedAt: new Date().toISOString(),
  cursor: { x: -200, y: 300 },
  foregroundWindow: {
    hwnd: "0x1", processId: 100, processName: "explorer", title: "Program Manager",
    className: "Progman", bounds: { x: -1920, y: 0, width: 4480, height: 1440 },
    monitorId: "laptop", dpi: 120,
  },
  windowUnderCursor: null,
  targetWindow: null,
  focusedElement: {
    name: "Previously focused.txt", controlType: "ListItem",
    bounds: { x: -500, y: 100, width: 80, height: 60 },
  },
  elementUnderCursor: { name: "Desktop", controlType: "List" },
  selectedDesktopItems: [],
  selectedDesktopItemCount: 0,
  selectedDesktopItemsTruncated: false,
  monitors: [
    {
      id: "laptop", deviceName: "DISPLAY1", isPrimary: true,
      bounds: { x: -1920, y: 0, width: 1920, height: 1080 },
      workArea: { x: -1920, y: 0, width: 1920, height: 1040 }, dpi: 120,
    },
    {
      id: "external", deviceName: "DISPLAY2", isPrimary: false,
      bounds: { x: 0, y: 0, width: 2560, height: 1440 },
      workArea: { x: 0, y: 0, width: 2560, height: 1400 }, dpi: 96,
    },
  ],
};

test("summary distinguishes keyboard focus, desktop selection, and all monitors", () => {
  const summary = JSON.parse(summarizeSnapshot(snapshot));

  assert.equal(summary.focusedElement.name, "Previously focused.txt");
  assert.match(summary.focusedElement.meaning, /does not imply selection/);
  assert.deepEqual(summary.selectedDesktopItems, []);
  assert.equal(summary.selectedDesktopItemCount, 0);
  assert.equal(summary.selectedDesktopItemsTruncated, false);
  assert.equal(summary.elementUnderCursor.name, "Desktop");
  assert.equal(summary.cursor.monitorId, "laptop");
  assert.equal(summary.monitors.length, 2);
  assert.deepEqual(summary.monitors.map((monitor: { dpi: number }) => monitor.dpi), [120, 96]);
});

test("summary reports actual selected desktop items separately", () => {
  const selected = {
    ...snapshot,
    selectedDesktopItems: [{ name: "Selected.txt", controlType: "ListItem" }],
    selectedDesktopItemCount: 1,
  } satisfies DesktopContextSnapshot;

  const summary = JSON.parse(summarizeSnapshot(selected));
  assert.deepEqual(summary.selectedDesktopItems.map((item: { name: string }) => item.name), ["Selected.txt"]);
});

/** The latency probe's Brave sample (r2/latency §2): the same window as target, foreground and under the cursor. */
const braveWindow = {
  hwnd: "cg-48213", processId: 712, processName: "Brave Browser", title: "pi-mono/packages/coding-agent at main · earendil-works/pi-mono · GitHub",
  bounds: { x: 0, y: 38, width: 1728, height: 1079 }, monitorId: "display-1", dpi: 144,
};
const brave: DesktopContextSnapshot = {
  id: "ctx-probe", capturedAt: "2026-10-05T12:00:00Z", cursor: { x: 812, y: 455 },
  targetWindow: braveWindow, foregroundWindow: { ...braveWindow }, windowUnderCursor: { ...braveWindow },
  focusedElement: { name: braveWindow.title, controlType: "AXWebArea", bounds: { x: 0, y: 125, width: 1728, height: 992 } },
  elementUnderCursor: { name: "README.md", controlType: "AXLink", bounds: { x: 790, y: 440, width: 90, height: 20 } },
  selectedDesktopItems: null,
  browser: { name: "Brave", mode: "ax", pinned: true },
  screenshot: { kind: "png", filePath: "/captures/probe.png", imageId: "img-probe", bounds: { x: 0, y: 38, width: 1728, height: 1079 }, imageWidth: 1280, imageHeight: 799 },
  monitors: snapshot.monitors,
};

test("compact summary (macOS): no indentation, repeated windows as =target, no monitors, handles, pids or DPI", () => {
  const text = compactSnapshotSummary(brave);
  const summary = JSON.parse(text);
  assert(!text.includes("\n"));
  assert.deepEqual(summary.targetWindow, { app: "Brave Browser", title: braveWindow.title, bounds: braveWindow.bounds });
  assert.equal(summary.foregroundWindow, "=target");
  assert.equal(summary.windowUnderCursor, "=target");
  assert.deepEqual(summary.focusedElement, { name: braveWindow.title, role: "AXWebArea", bounds: { x: 0, y: 125, width: 1728, height: 992 } });
  assert.deepEqual(summary.screenshot, { width: 1280, height: 799 });
  assert.deepEqual(summary.cursor, { x: 812, y: 455 });
  assert.deepEqual(summary.browser, { name: "Brave", mode: "ax", pinned: true });
  for (const gone of ["monitors", "selectedDesktopItems", "hwnd", "processId", "dpi", "monitorId", "cg-48213", "712", "imageId", "probe.png"]) {
    assert(!text.includes(gone), gone);
  }
  // 790 → ~243 tokens in the latency probe; characters shrink alike.
  const before = summarizeSnapshot(brave).length;
  assert(text.length * 3 < before, `${text.length} chars vs ${before}`);
});

test("compact summary keeps what the window rules name: desktop selection, surface, document path; other windows stay whole", () => {
  const finder = {
    ...snapshot,
    targetWindow: { hwnd: "w9", processId: 9, processName: "Finder", title: "", surface: "finderDesktop" as const, documentPath: "/Users/fixture/Desktop",
      bounds: { x: 0, y: 0, width: 1440, height: 900 } },
    selectedDesktopItems: [{ name: "Selected.txt", controlType: "AXImage" }],
    selectedDesktopItemCount: 1,
    selectedDesktopItemsTruncated: false,
  } satisfies DesktopContextSnapshot;
  const summary = JSON.parse(compactSnapshotSummary(finder));
  assert.deepEqual(summary.targetWindow, { app: "Finder", surface: "finderDesktop", documentPath: "/Users/fixture/Desktop", bounds: { x: 0, y: 0, width: 1440, height: 900 } });
  assert.deepEqual(summary.selectedDesktopItems, [{ name: "Selected.txt", role: "AXImage" }]);
  assert.equal(summary.selectedDesktopItemCount, 1);
  assert.equal(summary.selectedDesktopItemsTruncated, false);
  assert.deepEqual(summary.foregroundWindow, { app: "explorer", title: "Program Manager", bounds: { x: -1920, y: 0, width: 4480, height: 1440 } });
  assert.equal(summary.windowUnderCursor, undefined);
  assert.equal(summary.screenshot, undefined, "no screenshot attached, no screenshot member");
  // Defense in depth: credential fields never show a value, whatever the host sent.
  for (const field of [{ name: "Password", controlType: "AXTextField" }, { name: "PIN", controlType: "AXSecureTextField" }, { name: "Passwort:", controlType: "AXTextField" }]) {
    const leaked = JSON.parse(compactSnapshotSummary({ ...finder, focusedElement: { ...field, value: "dummy-secret" } }));
    assert.equal(leaked.focusedElement.value, undefined, field.name);
  }
  assert.equal(JSON.parse(compactSnapshotSummary({ ...finder, focusedElement: { name: "Subject", controlType: "AXTextField", value: "Q3" } })).focusedElement.value, "Q3");
  // A partial host result (use_active_window shows desktop.getContext as is) never throws.
  assert.equal(compactSnapshotSummary({ id: "x" } as unknown as DesktopContextSnapshot), "{}");
});
