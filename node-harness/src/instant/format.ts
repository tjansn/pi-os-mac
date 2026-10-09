/**
 * Display formatting for instant results. Numbers are grouped as strings so
 * fend's arbitrary-precision output never passes through a float; copy
 * values stay plain ("4294967296", "85.93").
 */

const MAX_DISPLAY = 200;
/** Formatter caches are keyed by request locale; cap them so odd locales cannot grow memory. */
export const MAX_CACHED_FORMATTERS = 128;

export function remember<K, V>(cache: Map<K, V>, key: K, value: V): V {
  if (cache.size >= MAX_CACHED_FORMATTERS) cache.clear();
  cache.set(key, value);
  return value;
}

export function truncate(text: string, max = MAX_DISPLAY): string {
  return text.length <= max ? text : `${text.slice(0, max - 1)}…`;
}

const separatorCache = new Map<string, { group: string; decimal: string }>();

export function separators(locale: string): { group: string; decimal: string } {
  let cached = separatorCache.get(locale);
  if (!cached) {
    try {
      const parts = new Intl.NumberFormat(locale).formatToParts(12345.6);
      cached = {
        group: parts.find((part) => part.type === "group")?.value ?? ",",
        decimal: parts.find((part) => part.type === "decimal")?.value ?? ".",
      };
    } catch {
      cached = { group: ",", decimal: "." };
    }
    remember(separatorCache, locale, cached);
  }
  return cached;
}

/** "4294967296" → "4,294,967,296" (en) / "4.294.967.296" (de); "1.5" → "1,5" (de). Non-numbers pass through. */
export function groupNumber(text: string, locale: string): string {
  const m = /^(-?)(\d+)(?:\.(\d+))?$/.exec(text);
  if (!m) return text;
  const { group, decimal } = separators(locale);
  const integer = m[2]!.length > 4 ? m[2]!.replace(/\B(?=(\d{3})+(?!\d))/g, group) : m[2]!;
  return `${m[1]}${integer}${m[3] !== undefined ? decimal + m[3] : ""}`;
}

/**
 * Display form of a fend value: groups the leading number, keeps the unit,
 * and shortens integers longer than 40 digits to scientific notation (the
 * copy value keeps every digit).
 */
export function displayValue(text: string, locale: string, approximate = false): string {
  const m = /^(-?\d+(?:\.\d+)?)(.*)$/.exec(text);
  let shown = text;
  if (m) {
    const digits = m[1]!.replace(/^-/, "").split(".")[0]!;
    if (digits.length > 40) {
      const sign = m[1]!.startsWith("-") ? "-" : "";
      const mantissa = `${digits[0]}.${digits.slice(1, 11)}`.replace(/\.?0+$/, "");
      return truncate(`${sign}${groupNumber(mantissa, locale)} × 10^${digits.length - 1}${m[2]}`);
    }
    shown = `${groupNumber(m[1]!, locale)}${m[2]}`;
  }
  return truncate(approximate ? `≈ ${shown}` : shown);
}

/** Rounds the leading number of an approximate unit result ("22.2222222222 °C" → "22.2222 °C"). */
export function roundLeadingNumber(text: string, decimals: number): string {
  return text.replace(/^(-?\d+\.\d+)/, (value) => String(Number(Number(value).toFixed(decimals))));
}

/** Leading number only (copy value for conversions): "8.04672 km" → "8.04672". */
export function leadingNumber(text: string): string {
  return /^-?\d+(?:\.\d+)?/.exec(text)?.[0] ?? text;
}

const digitCache = new Map<string, number>();

export function currencyDigits(code: string): number {
  let digits = digitCache.get(code);
  if (digits === undefined) {
    try {
      digits = new Intl.NumberFormat("en", { style: "currency", currency: code }).resolvedOptions().maximumFractionDigits ?? 2;
    } catch {
      digits = 2;
    }
    remember(digitCache, code, digits);
  }
  return digits;
}

const numberFormats = new Map<string, Intl.NumberFormat | null>();

export function formatNumber(value: number, locale: string, maximumFractionDigits: number, minimumFractionDigits = 0): string {
  const key = `${locale}|${maximumFractionDigits}|${minimumFractionDigits}`;
  let format = numberFormats.get(key);
  if (format === undefined) {
    try {
      format = new Intl.NumberFormat(locale, { maximumFractionDigits, minimumFractionDigits });
    } catch {
      format = null;
    }
    remember(numberFormats, key, format);
  }
  return format ? format.format(value) : value.toFixed(maximumFractionDigits);
}

export function displayLocale(requested: string | undefined, lang: "en" | "de"): string {
  if (requested) {
    try {
      return Intl.getCanonicalLocales(requested)[0] ?? (lang === "de" ? "de-DE" : "en-US");
    } catch {
      // fall through to the language default
    }
  }
  return lang === "de" ? "de-DE" : "en-US";
}
