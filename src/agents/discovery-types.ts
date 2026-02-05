export type DiscoveredModel = {
    id: string;
    name?: string;
    provider: string;
    contextWindow?: number;
    reasoning?: boolean;
    input?: Array<"text" | "image">;
};

export interface ModelDiscoverySource {
    discover(context: { config?: any; env?: NodeJS.ProcessEnv }): Promise<DiscoveredModel[]>;
}
