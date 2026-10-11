import type { JSONValue } from "./types.js";
export type Configuration = {
    [key: string]: JSONValue;
};
export interface CredentialDefinition {
    label: string;
    header: string;
    prefix?: string;
    help?: string;
}
export interface ProviderAccess {
    capability: "http" | "folder";
    origin?: string;
    allowedHeaders: string[];
    credential?: CredentialDefinition;
}
export interface ProviderManifest extends ProviderAccess {
    id: string;
    name: string;
    description?: string;
    defaultConfiguration: Configuration;
    configurationSchema?: Configuration;
    autoPublishLabel?: string;
    removalMessage?: string;
    connectAction?: string;
}
export interface Provider extends ProviderManifest {
    program?: string;
    programFingerprint?: string;
    unavailable?: boolean;
}
export interface ConnectorField {
    type: "text" | "textarea" | "number" | "boolean" | "select" | "template" | "folder";
    path: Array<string | number>;
    label: string;
    help?: string;
    placeholder?: string;
    disabled?: boolean;
    options?: Array<{
        label: string;
        value: JSONValue;
    }>;
    value?: JSONValue;
    row?: string;
    action?: string;
    context?: "path" | "property" | "body";
    multiline?: boolean;
    links?: Array<{
        id: string;
        name: string;
    }>;
    current?: string;
}
export interface ConnectorAction {
    type: "action";
    row?: string;
    id: string;
    label: string;
    disabled?: boolean;
    destructive?: boolean;
}
export interface ConnectorSection {
    title?: string;
    help?: string;
    fields: Array<ConnectorField | ConnectorAction>;
}
export interface ConnectorPreview {
    title?: string;
    text?: string;
    properties?: Array<{
        label: string;
        value: string;
    }>;
}
export interface ConnectorView {
    sections: ConnectorSection[];
    problem?: string;
    subtitle?: string;
    previews?: ConnectorPreview[];
}
export interface ConnectorEditorRequest {
    providerId: string;
    accountId?: string;
    configuration: Configuration;
    state?: Configuration;
    action?: string;
    value?: JSONValue;
}
export interface ConnectorEditorResult {
    [key: string]: unknown;
    configuration?: Configuration;
    state?: Configuration;
    view?: ConnectorView;
    valid?: boolean;
    problem?: string;
}
