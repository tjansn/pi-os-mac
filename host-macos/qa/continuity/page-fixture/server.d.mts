/** Types for server.mjs (the continuity page fixture), so node-harness tests can import it under `strict`. */

export declare const DEFAULT_PORT: number;
export declare const LOOPBACK: "127.0.0.1";
export declare const MAX_DELAY_MS: number;
export declare const PAGES: Readonly<Record<string, string>>;
export declare const PAGE_FIELDS: Readonly<Record<string, Readonly<Record<string, "text" | "credential">>>>;
export declare const SECURITY_HEADERS: Readonly<Record<string, string>>;

export interface TextFieldEcho {
  length: number;
  scalars: number;
  lineBreaks: number;
  replacements: number;
  inputs: number;
  returnKeys: number;
  focused: boolean;
}
export interface CredentialFieldEcho {
  filled: boolean;
  dummyMatches: boolean;
  returnKeys: number;
  focused: boolean;
}
export interface PageEcho {
  page: string;
  submits: number;
  fields: Record<string, TextFieldEcho | CredentialFieldEcho>;
  consent?: { accepted: number; rejected: number; open: boolean };
}
export interface PageFixtureState {
  pages: Record<string, PageEcho>;
  served: Record<string, number>;
}
export interface PageFixture {
  port: number;
  url: string;
  state(): PageFixtureState;
  close(): Promise<void>;
}

export declare function boundedDelay(raw: string | null | undefined, fallback: number): number;
export declare function parseEcho(value: unknown): PageEcho | null;
export declare function startPageFixture(options?: { port?: number; host?: string }): Promise<PageFixture>;
