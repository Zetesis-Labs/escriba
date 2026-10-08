export type JSONValue =
  | null
  | boolean
  | number
  | string
  | JSONValue[]
  | { [key: string]: JSONValue };
export interface Note {
  key: string;
  startedAt: string;
  text: string;
  segments: {
    start: number;
    end: number;
    speaker?: string | null;
    text: string;
  }[];
  digest?: { title: string; summary: string; tags: string[] } | null;
  source: string;
  timeZone: string;
}
export interface Change {
  expectedContents?: string | null;
  path: string;
  contents: string | null;
}
export interface Host {
  fetch: typeof fetch;
  files: {
    snapshot(): Promise<Record<string, string>>;
    apply(changes: Change[]): Promise<void>;
  };
  audio(): Promise<{ data: Blob; filename: string } | null>;
  checkpoint(receipt: Receipt): Promise<void>;
}
export interface Receipt {
  version: 1;
  provider: "okf" | "notion";
  locator: string;
  url?: string;
  key?: string;
  folder?: string;
  files?: Record<string, string>;
  pending?: Record<string, string>;
  state?: string;
}
export interface Request {
  destination?: string;
  input?: unknown;
  operation:
    | "manifest"
    | "template"
    | "validate"
    | "publish"
    | "remove"
    | "discover"
    | "migrate"
    | "preview";
  provider?: "okf" | "notion";
  config?: Record<string, unknown>;
  note?: Note;
  previous?: Partial<Receipt>;
  now?: string;
}
export interface Result {
  locator?: string;
  url?: string;
  receipt?: Receipt;
  [key: string]: unknown;
}
