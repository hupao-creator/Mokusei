import type { JsonObject } from '@mokusei/contracts'
import type { CollectionKey, CommandKey, Page, PageRequest, QueryKey, ThreadTypeKey } from '@mokusei/application-contracts'
import { defineValueContract } from '@mokusei/application-contracts'
import { z } from 'zod'

export interface GitSnapshot {
  readonly root: string
  readonly branch: string | null
  readonly head: string | null
  readonly upstream: string | null
  /** Null means unavailable, including an upstream ref that has disappeared. */
  readonly ahead: number | null
  readonly behind: number | null
  readonly changed: number
  readonly staged: number
  readonly unstaged: number
  readonly untracked: number
  readonly conflicts: number
}
export type GitReadError = 'unavailable' | 'timeout' | 'too-large' | 'inaccessible'
export interface GitSyncStatus {
  readonly attemptedAt: number
  readonly observedAt: number
  readonly error: GitReadError | null
}
/** Discovery seeds outlive the tasks which introduced their directory tags. */
export interface GitDirectory {
  readonly cwd: string
  readonly directoryTags: readonly string[]
}
export interface GitView {
  readonly snapshot: GitSnapshot
  readonly sync: GitSyncStatus
  readonly available: boolean
}
export interface GitWorktreeData extends GitView {
  readonly directoryTags: readonly string[]
  readonly archived: boolean
}
export interface GitActivity extends GitWorktreeData { readonly id: string }
export interface GitSyncInput {
  readonly directories: readonly GitDirectory[]
  readonly observations: readonly GitObservation[]
}
export interface GitObservation {
  readonly root: string
  readonly directoryTags: readonly string[]
  readonly attemptedAt: number
  /** Null means the worktree is confirmed missing or is no longer a Git worktree. */
  readonly snapshot?: GitSnapshot | null
  readonly error?: GitReadError
}
const id = z.string().min(1).max(256)
const path = z.string().min(1).max(32_768)
const text = z.string().max(4096)
const time = z.number().finite().nonnegative()
const count = z.number().int().nonnegative()
const error = z.enum(['unavailable', 'timeout', 'too-large', 'inaccessible'])
const sync = z.strictObject({ attemptedAt: time, observedAt: time, error: error.nullable() })
const directoryTags = z.array(z.string().min(1))
const directory = z.strictObject({ cwd: path, directoryTags })
export const gitSnapshotSchema = z.strictObject({ root: path, branch: text.nullable(), head: text.nullable(),
  upstream: text.nullable(), ahead: count.nullable(), behind: count.nullable(),
  changed: count, staged: count, unstaged: count, untracked: count, conflicts: count })
const view = z.strictObject({ snapshot: gitSnapshotSchema, sync, available: z.boolean() })
const worktreeData = view.extend({ directoryTags, archived: z.boolean() })
const observation = z.strictObject({ root: path, directoryTags, attemptedAt: time,
  snapshot: gitSnapshotSchema.nullable().optional(), error: error.optional() })
  .refine(value => (value.snapshot !== undefined) !== (value.error !== undefined))
  .refine(value => !value.snapshot || value.snapshot.root === value.root)
function contract<T>(name: string, schema: z.ZodType<T>) {
  return defineValueContract(name, value => schema.parse(value), z.toJSONSchema(schema, { io: 'input' }) as JsonObject)
}
const operation = <I, O>(name: string, input: z.ZodType<I>, output: z.ZodType<O>) => ({ id: name, ownerPluginId: 'git',
  input: contract(`${name}.input`, input), output: contract(`${name}.output`, output) })
const page = z.strictObject({ cursor: z.string().optional(), limit: z.number().int().min(1).max(1000) })
export const gitContracts: {
  directories: CollectionKey<GitDirectory>
  worktrees: CollectionKey<GitWorktreeData>
  thread: ThreadTypeKey<GitView>
  sync: CommandKey<GitSyncInput, null>
  list: QueryKey<PageRequest, Page<GitActivity>>
  listDirectories: QueryKey<PageRequest, Page<GitDirectory>>
} = {
  directories: { id: 'git.directories', ownerPluginId: 'git', retention: 'history', contract: contract<GitDirectory>('git.directory', directory) },
  worktrees: { id: 'git.worktrees', ownerPluginId: 'git', retention: 'history', contract: contract<GitWorktreeData>('git.worktree', worktreeData) },
  thread: { id: 'git.activity', ownerPluginId: 'git', contract: contract<GitView>('git.view', view) },
  sync: { kind: 'command', ...operation<GitSyncInput, null>('git.sync',
    z.strictObject({ directories: z.array(directory), observations: z.array(observation) }), z.null()) },
  list: { kind: 'query', ...operation<PageRequest, Page<GitActivity>>('git.list', page,
    z.strictObject({ items: z.array(worktreeData.extend({ id })), nextCursor: z.string().optional() })) },
  listDirectories: { kind: 'query', ...operation<PageRequest, Page<GitDirectory>>('git.list-directories', page,
    z.strictObject({ items: z.array(directory), nextCursor: z.string().optional() })) }
}

export function hasGitActivity(snapshot: GitSnapshot): boolean {
  return Boolean(snapshot.changed || snapshot.conflicts || (snapshot.ahead ?? 0) || (snapshot.behind ?? 0))
}

/** An unavailable upstream comparison must not be mistaken for synchronization. */
export function isGitSettled(snapshot: GitSnapshot): boolean {
  return !snapshot.changed && !snapshot.conflicts && (!snapshot.upstream || snapshot.ahead === 0 && snapshot.behind === 0)
}
