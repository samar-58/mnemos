import * as z from "zod/v4";

export const memoryEpisodeSchema = z.object({
  id: z.string().min(1),
  startedAt: z.iso.datetime(),
  endedAt: z.iso.datetime(),
  title: z.string(),
  summary: z.string(),
  projectKey: z.string().optional(),
  applications: z.array(z.string()),
  artifacts: z.array(z.string()),
  lastState: z.string().optional(),
  eventCount: z.number().int().nonnegative(),
  importance: z.number().min(0).max(1),
  isOpen: z.boolean(),
});

export const memorySearchResultSchema = z.object({
  episode: memoryEpisodeSchema,
  score: z.number().nonnegative(),
  highlights: z.array(z.string()),
});

export const episodeEvidenceSchema = z.object({
  id: z.string().min(1),
  timestamp: z.iso.datetime(),
  kind: z.string(),
  applicationName: z.string(),
  windowTitle: z.string().optional(),
  url: z.string().optional(),
  documentPath: z.string().optional(),
  target: z.string().optional(),
  detail: z.string().optional(),
});

export const episodesEnvelopeSchema = z.object({
  data: z.array(memoryEpisodeSchema),
});

export const searchEnvelopeSchema = z.object({
  data: z.array(memorySearchResultSchema),
});

export const episodeEnvelopeSchema = z.object({
  data: memoryEpisodeSchema,
});

export const evidenceEnvelopeSchema = z.object({
  data: z.array(episodeEvidenceSchema),
});

export const searchMemoryOutputSchema = z.object({
  results: z.array(memorySearchResultSchema),
  resultCount: z.number().int().nonnegative(),
  trustBoundary: z.string(),
});

export const recentActivityOutputSchema = z.object({
  episodes: z.array(memoryEpisodeSchema),
  episodeCount: z.number().int().nonnegative(),
  trustBoundary: z.string(),
});

export const episodeOutputSchema = z.object({
  episode: memoryEpisodeSchema,
  trustBoundary: z.string(),
});

export const evidenceOutputSchema = z.object({
  episodeId: z.string(),
  evidence: z.array(episodeEvidenceSchema),
  evidenceCount: z.number().int().nonnegative(),
  trustBoundary: z.string(),
});

export type MemoryEpisode = z.infer<typeof memoryEpisodeSchema>;
export type MemorySearchResult = z.infer<typeof memorySearchResultSchema>;
export type EpisodeEvidence = z.infer<typeof episodeEvidenceSchema>;
