export const UI_CONTROLLER_METHODS = [
  "controller_status",
  "credential_save",
  "connector_http",
  "resolver_models",
  "resolver_try",
] as const;
export const SHELL_CONTROLLER_METHODS = ["remote_transcribe", "remote_ask"] as const;
export type ControllerMethod = (typeof UI_CONTROLLER_METHODS)[number];
export type ShellControllerMethod = (typeof SHELL_CONTROLLER_METHODS)[number];
