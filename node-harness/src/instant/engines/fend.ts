import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";

/**
 * fend-wasm 1.5.8 calculator (MIT; arbitrary precision, units, bases, %),
 * loaded manually so it runs on Node 22.19+ without the Wasm ESM integration
 * (no flag, no experimental warning): the package's own fend_wasm.js entry
 * does `import * as wasm from "./fend_wasm_bg.wasm"`, so it is never imported.
 *
 * Instead the .wasm bytes are compiled once and instantiated against a fresh
 * copy of the wasm-bindgen glue (fend_wasm_bg.js). The glue keeps module-level
 * state (heap slots, cached memory views), so every instance gets its own glue
 * module via a query-string cache buster. A new instance is also the only way
 * to replace currency rates: fend stores them in a write-once OnceLock.
 *
 * The glue's `Function` constructor import (wasm-bindgen's global-object
 * fallback) is replaced with a stub that throws, so evaluation can never reach
 * eval/new Function. Node always provides globalThis, so the fallback is not
 * needed.
 */

export type FendResult =
  | { ok: true; text: string; approximate: boolean }
  | { ok: false; error: string };

interface FendGlue {
  __wbg_set_wasm(exports: unknown): void;
  evaluateFendWithTimeout(input: string, timeout: number): string;
  initialiseWithHandlers(currencyData: Map<string, number>): void;
}

// tsconfig's lib (ES2023) carries no WebAssembly typings (they live in lib.dom); declare the surface used here.
interface WasmModule { readonly kind?: "wasm-module" }
interface WasmInstance { readonly exports: Record<string, unknown> }
type WasmImports = Record<string, Record<string, unknown>>;
const Wasm = (globalThis as unknown as {
  WebAssembly: {
    compile(bytes: Uint8Array): Promise<WasmModule>;
    instantiate(module: WasmModule, imports: WasmImports): Promise<WasmInstance>;
  };
}).WebAssembly;

export const FEND_MAX_INPUT = 500;
export const FEND_DEFAULT_TIMEOUT_MS = 30;

let compiled: Promise<WasmModule> | undefined;
let generation = 0;

function packageDir(): string {
  return dirname(createRequire(import.meta.url).resolve("fend-wasm/package.json"));
}

function compileOnce(dir: string): Promise<WasmModule> {
  if (!compiled) {
    compiled = readFile(join(dir, "fend_wasm_bg.wasm")).then((bytes) => Wasm.compile(bytes));
    compiled.catch(() => { compiled = undefined; });
  }
  return compiled;
}

function blockedFunctionConstructor(): never {
  throw new Error("fend: Function constructor is disabled");
}

/** Glue exports as the wasm import object, with the Function-constructor import stubbed out (exported for tests). */
export function fendImportObject(glue: Record<string, unknown>): WasmImports {
  const imports: Record<string, unknown> = { ...glue };
  for (const name of Object.keys(imports)) {
    if (name.startsWith("__wbg_new_no_args_")) imports[name] = blockedFunctionConstructor;
  }
  return { "./fend_wasm_bg.js": imports };
}

async function instantiate(dir: string, rates?: ReadonlyMap<string, number>): Promise<FendGlue> {
  const module = await compileOnce(dir);
  const url = `${pathToFileURL(join(dir, "fend_wasm_bg.js")).href}?instance=${++generation}`;
  const glue = (await import(url)) as Record<string, unknown> & FendGlue;
  const instance = await Wasm.instantiate(module, fendImportObject(glue));
  glue.__wbg_set_wasm(instance.exports);
  if (rates?.size) glue.initialiseWithHandlers(new Map(rates));
  return glue;
}

export class FendEngine {
  private glue: FendGlue | undefined;
  private reloading: Promise<void> | undefined;
  private rates: ReadonlyMap<string, number> | undefined;

  private constructor(private readonly dir: string) {}

  /** Compiles (once per process) and instantiates fend. Rates are EUR-relative units per EUR (ECB layout). */
  static async load(options: { rates?: ReadonlyMap<string, number>; dir?: string } = {}): Promise<FendEngine> {
    const engine = new FendEngine(options.dir ?? packageDir());
    await engine.reload(options.rates);
    return engine;
  }

  get ready(): boolean {
    return this.glue !== undefined;
  }

  get hasRates(): boolean {
    return (this.rates?.size ?? 0) > 0;
  }

  /** Resolves once a pending reload (e.g. the rebuild after a trap) has finished, successfully or not. */
  settled(): Promise<void> {
    return this.reloading ?? Promise.resolve();
  }

  /** Swaps in a fresh instance (new rates or recovery). The old instance is released for GC. */
  reload(rates?: ReadonlyMap<string, number>): Promise<void> {
    this.rates = rates;
    const run = instantiate(this.dir, rates).then((glue) => {
      const previous = this.glue;
      this.glue = glue;
      previous?.__wbg_set_wasm(undefined);
    });
    const tracked: Promise<void> = run.catch(() => undefined).finally(() => {
      if (this.reloading === tracked) this.reloading = undefined;
    });
    this.reloading = tracked;
    return run;
  }

  /** Synchronous evaluation in the wasm sandbox with fend's wall-clock interrupt. Never throws. */
  evaluate(expression: string, timeoutMs = FEND_DEFAULT_TIMEOUT_MS): FendResult {
    const glue = this.glue;
    if (!glue) {
      this.recover();
      return { ok: false, error: "engine_unavailable" };
    }
    const input = expression.trim();
    if (!input) return { ok: false, error: "empty" };
    if (input.length > FEND_MAX_INPUT) return { ok: false, error: "too_long" };
    let out: string;
    try {
      out = glue.evaluateFendWithTimeout(input, Math.max(1, Math.min(timeoutMs, 1_000)));
    } catch {
      // A trap can leave wasm-bindgen state inconsistent: drop this instance and rebuild in the background.
      this.glue = undefined;
      this.recover();
      return { ok: false, error: "engine_error" };
    }
    if (out.startsWith("Error: ")) return { ok: false, error: out.slice(7) };
    if (out === "") return { ok: false, error: "empty" };
    const approximate = out.startsWith("approx. ");
    return { ok: true, text: approximate ? out.slice(8) : out, approximate };
  }

  /** Starts a background rebuild unless one is running (also retries a rebuild that failed). */
  private recover(): void {
    if (!this.reloading) this.reload(this.rates).catch(() => undefined);
  }
}
