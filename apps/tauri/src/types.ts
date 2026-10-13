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
  personId?: string | null;
  words?: { start: number; end: number; text: string }[];
  timingShared?: boolean;
}
export interface Transcript {
  text: string;
  segments: Segment[];
  recognitions?: Recognition[];
  language?: string;
  duration?: number;
}
export interface Recognition {
  speaker: string;
  person: string;
  distance: number;
}
export interface PersonVoice {
  id: string;
  source: string;
  addedAt: string;
  model: string;
}
export interface Person {
  id?: string;
  name: string;
  color?: string;
  voices: PersonVoice[];
}
export interface VoiceRegistration {
  state: "idle" | "requesting" | "recording" | "analyzing" | "failed";
  person?: string;
  message?: string;
  startedAt?: string;
}
export interface Digest {
  title: string;
  summary: string;
  description?: string;
  tags: string[];
}
export interface Version {
  id: string;
  title?: string;
  revision?: string;
  createdAt: string;
  backend: string;
  recipeId?: string;
  transcript: Transcript;
  digest?: Digest | null;
  data?: JSONValue;
  dataSchema?: JSONValue;
  inputs?: JSONObject;
  hasVoices?: boolean;
  learnedVoice?: boolean;
}
export interface NoteContent {
  title: string;
  transcript: Transcript;
  digest: Digest | null;
  data: JSONValue;
}
export interface NoteDraft {
  id: string;
  recordingId: string;
  baseVersionId: string;
  baseFingerprint: string;
  revision: number;
  createdAt: string;
  updatedAt: string;
  content: NoteContent;
}
export interface NoteDraftCommit {
  version: Version;
  created: boolean;
}
export interface Publication {
  managed?: boolean;
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
  accountEffectPending?: boolean;
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
  ontologies?: import("./core/ontologyDependencies").OntologyDependency[];
  id: string;
  name: string;
  kind: "form" | "code";
  values: JSONObject;
  base?: string;
  entry?: string;
  description?: string;
  schema?: JSONObject;
  bundle?: string;
  bundleFingerprint?: string;
  error?: string;
}
export type { Provider, ProviderAccess } from "@escriba/conectores";
export interface Account {
  id: string;
  name: string;
  provider: string;
  enabled: boolean;
  folder?: string;
  origin?: string;
  hasCredential?: boolean;
  grant?: import("@escriba/conectores").ProviderAccess;
}
export interface Destination {
  managed?: boolean;
  id: string;
  name: string;
  provider: string;
  account: string;
  enabled: boolean;
  configuration: JSONObject;
  inputSchema?: JSONObject;
  description?: string;
  program?: string;
  programFingerprint?: string;
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
  notifyEveryNote?: boolean;
  launchAtLogin: boolean;
  jobHistoryDays?: number | null;
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
  providers?: import("@escriba/conectores").Provider[];
  recordings: Recording[];
  resolvers: Resolver[];
  recipes: Recipe[];
  accounts: Account[];
  destinations: Destination[];
  settings: Settings;
  dataPath: string;
  native?: NativeStatus;
  platform?: import("./core/platform").Platform;
  watchIssues?: Array<{
    folderId: string;
    path: string;
    message: string;
    permissionDenied: boolean;
  }>;
}
export interface ProcessOptions {
  recipeId?: string;
  values?: JSONObject;
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

export interface RecipeTrace {
  id: string;
  recordingId: string;
  jobId?: string;
  recipeId?: string;
  dryRun: boolean;
  startedAt: string;
  finishedAt: string;
  error?: string | null;
  errorCode?: string | null;
  steps: {
    capability: string;
    origin?: string;
    seconds: number;
    error?: string;
  }[];
  result?: JSONValue;
}
