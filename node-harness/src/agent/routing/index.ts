/**
 * Auto model router (DESIGN.md §3.4). Entry points for the node wiring:
 * classifyUtterance → classificationFromHints → decide (before prompt), and
 * registerAutoModel per session runtime (route() consumes the decision).
 * contextScope scores "is this about the active window?" for /instant (advisory).
 */
export * from "./types.js";
export * from "./heuristics.js";
export * from "./contextScope.js";
export * from "./fusion.js";
export * from "./decide.js";
export * from "./profiles.js";
export * from "./settings.js";
export * from "./latencyStats.js";
export * from "./escalate.js";
export * from "./autoModel.js";
export * from "./routeInput.js";
