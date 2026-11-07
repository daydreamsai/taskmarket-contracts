export interface InspectedManifest {
  publishable: boolean;
  manifest: Record<string, unknown> | null;
  errors: string[];
}
export function inspectJson(source: string): InspectedManifest;
export function validateJson(source: string): string[];
