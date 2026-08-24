import * as z from "zod/v4";

export const workstreamSchema = z.object({
  id: z.string().min(1),
  kind: z.enum(["git_repository", "local_project", "website", "conversation", "custom"]),
  canonicalKey: z.string(),
  displayName: z.string(),
  userConfirmed: z.boolean(),
});

export const workSessionSchema = z.object({
  id: z.string().min(1),
  startedAt: z.iso.datetime(),
  endedAt: z.iso.datetime(),
  taskCount: z.number().int().nonnegative(),
  applications: z.array(z.string()),
  isOpen: z.boolean(),
});

export const taskMemorySchema = z.object({
  id: z.string().min(1), sessionID: z.string().min(1), workstream: workstreamSchema.optional(),
  startedAt: z.iso.datetime(), endedAt: z.iso.datetime(), title: z.string(), digest: z.string(),
  actions: z.array(z.string()), applications: z.array(z.string()), artifacts: z.array(z.string()),
  lastState: z.string().optional(), eventCount: z.number().int().nonnegative(), isPinned: z.boolean(),
  groupingConfidence: z.number().min(0).max(1), groupingReasons: z.array(z.string()),
  isOpen: z.boolean(), isUserLocked: z.boolean(),
});

export const activitySpanSchema = z.object({
  id: z.string().min(1), taskID: z.string().min(1), startedAt: z.iso.datetime(), endedAt: z.iso.datetime(),
  applicationName: z.string(), bundleID: z.string(), windowTitle: z.string().optional(),
  documentPath: z.string().optional(), url: z.string().optional(), anchorKey: z.string().optional(),
  eventCount: z.number().int().nonnegative(),
});

export const evidenceItemSchema = z.object({
  id: z.string().min(1), taskID: z.string().min(1), observationID: z.string().optional(),
  timestamp: z.iso.datetime(), kind: z.string(), applicationName: z.string(), excerpt: z.string().optional(),
  url: z.string().optional(), documentPath: z.string().optional(), target: z.string().optional(),
  source: z.enum(["raw", "compacted", "user_selected"]), priority: z.number().int(),
  redactionPolicyVersion: z.number().int().positive(),
});

export const memorySearchResultSchema = z.object({
  task: taskMemorySchema, score: z.number().nonnegative(), highlights: z.array(z.string()),
  matchReasons: z.array(z.string()), evidencePreviews: z.array(evidenceItemSchema),
});
export const taskContextSchema = z.object({
  task: taskMemorySchema, spans: z.array(activitySpanSchema), evidence: z.array(evidenceItemSchema),
  previousTask: taskMemorySchema.optional(), nextTask: taskMemorySchema.optional(),
});
export const contextPackSchema = z.object({
  query: z.string().optional(), results: z.array(memorySearchResultSchema), generatedAt: z.iso.datetime(),
});
export const timelineEntrySchema = z.object({ task: taskMemorySchema, session: workSessionSchema });

export const searchEnvelopeSchema = z.object({ data: z.array(memorySearchResultSchema) });
export const contextEnvelopeSchema = z.object({ data: contextPackSchema });
export const taskEnvelopeSchema = z.object({ data: taskContextSchema });
export const timelineEnvelopeSchema = z.object({ data: z.array(timelineEntrySchema) });
export const recentEnvelopeSchema = z.object({
  data: z.object({ sessions: z.array(workSessionSchema), tasks: z.array(taskMemorySchema) }),
});
export const evidencePageSchema = z.object({
  data: z.array(evidenceItemSchema), nextCursor: z.iso.datetime().optional(),
});

export const searchMemoryOutputSchema = z.object({
  results: z.array(memorySearchResultSchema), resultCount: z.number().int().nonnegative(), trustBoundary: z.string(),
});
export const recentActivityOutputSchema = z.object({
  sessions: z.array(workSessionSchema), tasks: z.array(taskMemorySchema), trustBoundary: z.string(),
});
export const episodeOutputSchema = z.object({ context: taskContextSchema, trustBoundary: z.string() });
export const evidenceOutputSchema = z.object({
  episodeId: z.string(), evidence: z.array(evidenceItemSchema), nextCursor: z.string().optional(), trustBoundary: z.string(),
});
export const recallContextOutputSchema = z.object({ context: contextPackSchema, trustBoundary: z.string() });
export const timelineOutputSchema = z.object({ entries: z.array(timelineEntrySchema), trustBoundary: z.string() });

export type TaskMemory = z.infer<typeof taskMemorySchema>;
export type MemorySearchResult = z.infer<typeof memorySearchResultSchema>;
export type EvidenceItem = z.infer<typeof evidenceItemSchema>;
