export type JSONValue =
  | null
  | boolean
  | number
  | string
  | JSONValue[]
  | { [key: string]: JSONValue };
export type JSONObject = { [key: string]: JSONValue };
export interface Segment {
  start: number;
  end: number;
  text: string;
  speaker?: string | null;
  words?: { start: number; end: number; text: string }[];
}
export interface Transcript {
  text: string;
  segments: Segment[];
  language?: string;
  duration?: number;
}
export interface Digest {
  title: string;
  summary: string;
  tags: string[];
}
export interface Version {
  id: string;
  createdAt: string;
  backend: string;
  recipeId?: string;
  transcript: Transcript;
  digest?: Digest | null;
  data?: JSONValue;
  inputs?: JSONObject;
}
export interface Publication {
  destinationId: string;
  accountId?: string;
  name: string;
  provider: string;
  receipt: JSONObject;
  configuration: JSONObject;
  program?: string;
  updatedAt: string;
  error?: string;
}
export interface Recording {
  id: string;
  title: string;
  createdAt: string;
  source: string;
  audioPath: string | null;
  audioHash?: string;
  duration: number;
  status: "pending" | "processing" | "done" | "failed" | "discarded";
  error?: string | null;
  recipeId?: string;
  currentVersionId?: string;
  versions: Version[];
  publications: Publication[];
}
export interface Resolver {
  id: string;
  name: string;
  role: "stt" | "llm";
  local: boolean;
  enabled: boolean;
  url?: string;
  model?: string;
  hasCredential?: boolean;
}
export interface Recipe {
  id: string;
  name: string;
  kind: "form" | "code";
  values: JSONObject;
  base?: string;
  entry?: string;
  description?: string;
  schema?: JSONObject;
  bundle?: string;
  error?: string;
}
export interface Account {
  id: string;
  name: string;
  provider: "notion" | "okf";
  enabled: boolean;
  folder?: string;
  origin?: string;
  hasCredential?: boolean;
}
export interface Destination {
  id: string;
  name: string;
  provider: "notion" | "okf";
  account: string;
  enabled: boolean;
  configuration: JSONObject;
  inputSchema?: JSONObject;
  description?: string;
  program?: string;
}
export interface WatchedFolder {
  style?: "justPressRecord" | "voiceMemos" | "any";
  authorizationSaved?: boolean;
  id: string;
  path: string;
  name: string;
  enabled: boolean;
}
export interface Settings {
  defaultRecipeId: string;
  projectPath: string | null;
  watchedFolders: WatchedFolder[];
  language: string;
  whisperModel: string;
  autoProcess: boolean;
  notifyEveryNote?: boolean;
  launchAtLogin: boolean;
  theme: "system" | "light" | "dark";
  watchMigration?:
    | { state: "adopted"; count: number; paused: boolean }
    | { state: "preserved"; count: number }
    | { state: "error"; message: string };
  startupMigration?:
    | { state: "importing" }
    | { state: "error"; message: string }
    | {
        state: "imported";
        report: { recordings: number; audioMissing: number };
        completedAt: string;
        dismissed?: boolean;
      };
}
export interface LogEntry {
  id: string;
  at: string;
  level: "info" | "warn" | "error";
  message: string;
  recordingId?: string;
  recipeId?: string;
}
export interface NativeStatus {
  protocolVersion: number;
  whisper: { available?: boolean; modelsPath?: string; [key: string]: unknown };
  llm: { available?: boolean; reason?: string; [key: string]: unknown };
  [key: string]: unknown;
}
export interface Snapshot {
  recordings: Recording[];
  resolvers: Resolver[];
  recipes: Recipe[];
  accounts: Account[];
  destinations: Destination[];
  settings: Settings;
  logs: LogEntry[];
  dataPath: string;
  native?: NativeStatus;
  watchIssues?: Array<{
    folderId: string;
    path: string;
    message: string;
    permissionDenied: boolean;
  }>;
}
export interface ProcessOptions {
  recipeId?: string;
  stt?: string;
  llm?: string;
  language?: string;
  diarize?: boolean;
  speakers?: number;
  summarize?: boolean;
  dryRun?: boolean;
  force?: boolean;
}
export interface JobState {
  recordingId: string;
  stage: string;
  startedAt: number;
}

export interface RuntimeHistory extends JobState {
  id: string;
  operation: string;
  state: string;
  attempt: number;
  createdAt: number;
  error?: string | null;
  nextAttemptAt?: number;
  args?: JSONObject;
}
export interface RecipeTrace {
  id: string;
  recordingId: string;
  recipeId?: string;
  dryRun: boolean;
  startedAt: string;
  finishedAt: string;
  error?: string | null;
  steps: {
    capability: string;
    origin?: string;
    seconds: number;
    error?: string;
  }[];
  result?: JSONValue;
}
