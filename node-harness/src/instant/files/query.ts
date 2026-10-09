import type { FileSearchRequest } from "../../contracts/launcher.js";
import type { FileQuery } from "../types.js";

/**
 * FileQuery (from the grammar) → host FileSearchRequest. Name terms become
 * an OR of AND-groups widened with bilingual synonyms, so "invoice" also
 * finds "Rechnung_März.pdf". The host turns each term into a word-prefix
 * Spotlight match; dates are filtered in Node (date predicates in the
 * Spotlight query cost 3–4× more).
 */

export const FILE_SYNONYMS: Readonly<Record<string, readonly string[]>> = {
  invoice: ["rechnung"], invoices: ["rechnung"], rechnung: ["invoice"], rechnungen: ["invoice"],
  contract: ["vertrag"], contracts: ["vertrag"], vertrag: ["contract"], "verträge": ["contract"],
  receipt: ["quittung", "beleg"], receipts: ["quittung", "beleg"], quittung: ["receipt"], beleg: ["receipt"], belege: ["receipt"],
  resume: ["cv", "lebenslauf"], cv: ["resume", "lebenslauf"], lebenslauf: ["resume", "cv"],
  screenshot: ["bildschirmfoto"], bildschirmfoto: ["screenshot"],
  tax: ["steuer"], taxes: ["steuer"], steuer: ["tax"], steuern: ["tax"],
  offer: ["angebot"], angebot: ["offer"], letter: ["brief"], brief: ["letter"], report: ["bericht"], bericht: ["report"],
  insurance: ["versicherung"], versicherung: ["insurance"], lease: ["mietvertrag"], mietvertrag: ["lease"],
  payslip: ["gehaltsabrechnung", "lohnabrechnung"], gehaltsabrechnung: ["payslip"], lohnabrechnung: ["payslip"],
  photo: ["foto"], foto: ["photo"], notes: ["notizen"], notizen: ["notes"], presentation: ["präsentation"], "präsentation": ["presentation"],
};

export const MAX_NAME_TERMS = 6;
export const DEFAULT_MAX_RESULTS = 100;

export function buildFileSearchRequest(query: FileQuery, options: { contextId?: string; maxResults?: number } = {}): FileSearchRequest {
  const base = query.terms.slice(0, MAX_NAME_TERMS);
  const groups: string[][] = [base];
  let total = base.length;
  for (let i = 0; i < base.length; i++) {
    for (const synonym of FILE_SYNONYMS[base[i]!] ?? []) {
      const group = base.map((term, k) => (k === i ? synonym : term));
      if (total + group.length > MAX_NAME_TERMS) break;
      if (groups.some((g) => g.join("\u0000") === group.join("\u0000"))) continue;
      groups.push(group);
      total += group.length;
    }
  }
  return {
    ...(options.contextId ? { contextId: options.contextId } : {}),
    nameGroups: groups,
    ...(query.contentType ? { contentType: query.contentType } : {}),
    scopes: ["home"],
    maxResults: Math.min(200, Math.max(1, options.maxResults ?? DEFAULT_MAX_RESULTS)),
  };
}
