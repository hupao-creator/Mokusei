import { isDeepStrictEqual as equal } from 'node:util'
import { threadTagKey } from '@mokusei/contracts'
import type { Page, PageRequest, PluginDomainClient, QueryKey } from '@mokusei/application-contracts'
import { threadArchive, threadOverview, threadTags, type PluginMainRegistry } from '@mokusei/application-contracts/main'
import { gitContracts, hasGitActivity, isGitSettled, type GitWorktreeData } from '../shared/contracts.js'

const directories = gitContracts.directories
const worktrees = gitContracts.worktrees

export function registerGitDomain(registry: PluginMainRegistry): void {
  registry.collection({ key: directories })
  registry.collection({ key: worktrees })
  registry.query({ key: gitContracts.list, audience: { user: false, background: true }, requires: [],
    read: (input, context) => paginate(context.records.list(worktrees).map(record => ({ id: record.id, ...record.value })), input) })
  registry.query({ key: gitContracts.listDirectories, audience: { user: false, background: true }, requires: [],
    read: (input, context) => paginate(context.records.list(directories).map(record => record.value), input) })
  registry.command({ key: gitContracts.sync, audience: { user: false, background: 'allow-unbatched' }, requires: [],
    plan: (_input, context) => [context.records.scope(directories), context.records.scope(worktrees)],
    reduce(input, context) {
      const known = new Map(context.records.list(directories).map(record => [record.value.cwd, record]))
      for (const directory of input.directories) {
        const current = known.get(directory.cwd)
        const value = { cwd: directory.cwd, directoryTags: unique([...current?.value.directoryTags ?? [], ...directory.directoryTags]) }
        if (!current || !equal(current.value, value)) {
          const record = context.records.put(directories, current?.id ?? context.allocateId(`directory:${directory.cwd}`), value,
            { expectedRevision: current?.revision ?? null, touchUpdatedAt: true })
          known.set(directory.cwd, record)
        }
      }
      const existing = new Map(context.records.list(worktrees).map(record => [record.value.snapshot.root, record]))
      for (const observation of input.observations) {
        const current = existing.get(observation.root)
        if (current && observation.attemptedAt <= current.value.sync.attemptedAt) continue
        // Initial clean, unavailable and non-Git workspaces are discovery state, not Threads.
        if (!current && (!observation.snapshot || !hasGitActivity(observation.snapshot))) continue
        const previous = current?.value
        const snapshot = observation.snapshot ?? previous!.snapshot
        const value: GitWorktreeData = {
          directoryTags: unique([...previous?.directoryTags ?? [], ...observation.directoryTags]),
          snapshot,
          available: observation.error ? previous!.available : observation.snapshot !== null,
          archived: observation.error ? previous!.archived : observation.snapshot === null ? true
            : hasGitActivity(snapshot) ? false : isGitSettled(snapshot) ? true : previous!.archived,
          sync: { attemptedAt: observation.attemptedAt,
            observedAt: observation.error ? previous!.sync.observedAt : observation.attemptedAt,
            error: observation.error ?? null }
        }
        const meaningful = !previous || !equal({ ...previous, sync: undefined }, { ...value, sync: undefined })
        if (!meaningful && previous!.sync.error === value.sync.error && observation.attemptedAt - previous!.sync.attemptedAt < 60_000) continue
        const record = context.records.put(worktrees, current?.id ?? context.allocateId(`worktree:${observation.root}`), value,
          { expectedRevision: current?.revision ?? null, touchUpdatedAt: meaningful })
        existing.set(observation.root, record)
      }
      return null
    } })
  const thread = registry.threadType({ key: gitContracts.thread, displayName: 'Git', collection: worktrees,
    project: record => ({ title: record.value.snapshot.root.split(/[/\\]/u).filter(Boolean).at(-1) ?? record.value.snapshot.root,
      view: { snapshot: record.value.snapshot, sync: record.value.sync, available: record.value.available } }) })
  thread.extend(threadTags<GitWorktreeData>(), {
    project: record => ({ tags: record.value.directoryTags, semanticTags: [], directoryTags: record.value.directoryTags }),
    sources: () => [],
    apply: record => ({ value: record.value, touchUpdatedAt: false })
  })
  thread.extend(threadArchive<GitWorktreeData>(), {
    archived: record => record.value.archived,
    change: () => { throw new Error('Git Thread archive state is managed by local observation') },
    relatedLatestExecutions: () => []
  })
  thread.extend(threadOverview<GitWorktreeData>(), { tagFilter: 'directory', coversExecutions: () => [] })
}

function unique(tags: readonly string[]): string[] {
  const seen = new Set<string>()
  return tags.filter(tag => { const key = threadTagKey(tag); if (!key || seen.has(key)) return false; seen.add(key); return true })
}
function paginate<T>(items: readonly T[], input: PageRequest): Page<T> {
  const offset = Number(input.cursor ?? 0)
  if (!Number.isSafeInteger(offset) || offset < 0) throw new Error('Invalid Git cursor')
  return { items: items.slice(offset, offset + input.limit),
    ...(offset + input.limit < items.length ? { nextCursor: String(offset + input.limit) } : {}) }
}
export async function listGitRecords<T>(domain: PluginDomainClient, query: QueryKey<PageRequest, Page<T>>, signal: AbortSignal): Promise<T[]> {
  const rows: T[] = []
  let cursor: string | undefined
  do {
    const page = await domain.query(query, { limit: 1000, ...(cursor ? { cursor } : {}) }, { signal })
    rows.push(...page.items)
    cursor = page.nextCursor
  } while (cursor)
  return rows
}
