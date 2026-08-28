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

// V3 keeps generated memories and approved instructions structurally separate
// from captured evidence. These schemas deliberately mirror the Swift public
// models so malformed local API output fails closed at the MCP boundary.
export const resumeStateSchema = z.object({
  kind: z.enum(["document", "webpage", "terminal", "selection", "text", "window"]),
  value: z.string(), application: z.string(), timestamp: z.iso.datetime(),
  supportingEvidenceID: z.string().optional(),
});

export const derivedMemorySchema = z.object({
  id: z.string().min(1), versionID: z.string().min(1), version: z.number().int().positive(),
  scope: z.enum(["episode", "daily_workstream", "daily_recap"]), scopeID: z.string().min(1),
  workstream: workstreamSchema.optional(), startedAt: z.iso.datetime(), endedAt: z.iso.datetime(),
  title: z.string(), summary: z.string(),
  progress: z.enum(["in_progress", "completed", "blocked", "unknown"]),
  accomplishments: z.array(z.string()), blockers: z.array(z.string()), openLoops: z.array(z.string()),
  artifacts: z.array(z.string()), applications: z.array(z.string()), resumeState: resumeStateSchema.optional(),
  status: z.enum(["pending_enrichment", "current", "local_only", "failed", "superseded"]),
  authorship: z.enum(["deterministic", "model_derived", "user_authored"]),
  sourceCoverage: z.number().min(0).max(1), omittedSourceCount: z.number().int().nonnegative(),
  provider: z.string().optional(), model: z.string().optional(), createdAt: z.iso.datetime(), isUserLocked: z.boolean(),
});

export const memoryClaimSchema = z.object({
  id: z.string().min(1), memoryVersionID: z.string().min(1), kind: z.string(), text: z.string(),
  confidence: z.number().min(0).max(1), evidenceIDs: z.array(z.string()),
});

export const memorySearchV3ResultSchema = z.object({
  memory: derivedMemorySchema, score: z.number().nonnegative(), highlights: z.array(z.string()),
  matchReasons: z.array(z.string()), evidencePreviews: z.array(evidenceItemSchema),
});

export const workstreamStateSchema = z.object({
  id: z.string().min(1), workstream: workstreamSchema, summary: z.string(), decisions: z.array(z.string()),
  blockers: z.array(z.string()), openLoops: z.array(z.string()), artifacts: z.array(z.string()),
  lastMemoryID: z.string().optional(), updatedAt: z.iso.datetime(),
});

export const personalSkillSchema = z.object({
  id: z.string().min(1), currentVersionID: z.string().optional(), title: z.string(), description: z.string(),
  scopeWorkstreamID: z.string().optional(), status: z.enum(["candidate", "approved", "rejected", "retired"]),
  confidence: z.number().min(0).max(1), occurrenceCount: z.number().int().nonnegative(), updatedAt: z.iso.datetime(),
});

export const skillVersionSchema = z.object({
  id: z.string().min(1), skillID: z.string().min(1), version: z.number().int().positive(), trigger: z.string(),
  workflow: z.array(z.string()), preferences: z.array(z.string()), constraints: z.array(z.string()),
  verification: z.array(z.string()), evidenceMemoryIDs: z.array(z.string()),
  approvedAt: z.iso.datetime().optional(), createdAt: z.iso.datetime(),
});

export const relevantSkillSchema = z.object({
  skill: personalSkillSchema, version: skillVersionSchema, score: z.number().min(0).max(1),
  matchReasons: z.array(z.string()),
});

export const personalContextPackSchema = z.object({
  query: z.string().optional(), currentState: z.array(workstreamStateSchema),
  memories: z.array(memorySearchV3ResultSchema), approvedSkills: z.array(relevantSkillSchema),
  evidence: z.array(evidenceItemSchema), trustBoundary: z.string(), generatedAt: z.iso.datetime(),
});

export const memoryV3DetailSchema = z.object({ memory: derivedMemorySchema, claims: z.array(memoryClaimSchema) });
export const taskV3DetailSchema = z.object({
  task: taskContextSchema, memory: derivedMemorySchema.optional(), claims: z.array(memoryClaimSchema),
});
export const skillV3DetailSchema = z.object({ skill: personalSkillSchema, version: skillVersionSchema });

export const searchV3EnvelopeSchema = z.object({ data: z.array(memorySearchV3ResultSchema) });
export const recentV3EnvelopeSchema = z.object({ data: z.array(derivedMemorySchema) });
export const contextV3EnvelopeSchema = z.object({ data: personalContextPackSchema });
export const taskV3EnvelopeSchema = z.object({ data: taskV3DetailSchema });
export const skillV3EnvelopeSchema = z.object({ data: skillV3DetailSchema });
export const relevantSkillsV3EnvelopeSchema = z.object({ data: z.array(relevantSkillSchema) });
export const workstreamStateV3EnvelopeSchema = z.object({ data: workstreamStateSchema });

export const searchMemoryV3OutputSchema = z.object({
  results: z.array(memorySearchV3ResultSchema), resultCount: z.number().int().nonnegative(), trustBoundary: z.string(),
});
export const recentActivityV3OutputSchema = z.object({ memories: z.array(derivedMemorySchema), trustBoundary: z.string() });
export const episodeV3OutputSchema = z.object({ context: taskV3DetailSchema, trustBoundary: z.string() });
export const recallContextV3OutputSchema = z.object({ context: personalContextPackSchema, trustBoundary: z.string() });
export const timelineV3OutputSchema = z.object({ entries: z.array(memorySearchV3ResultSchema), trustBoundary: z.string() });
export const relevantSkillsOutputSchema = z.object({ skills: z.array(relevantSkillSchema), trustBoundary: z.string() });
export const skillOutputSchema = z.object({ skill: skillV3DetailSchema, trustBoundary: z.string() });
export const projectStateOutputSchema = z.object({ state: workstreamStateSchema, trustBoundary: z.string() });

export type TaskMemory = z.infer<typeof taskMemorySchema>;
export type MemorySearchResult = z.infer<typeof memorySearchResultSchema>;
export type EvidenceItem = z.infer<typeof evidenceItemSchema>;
