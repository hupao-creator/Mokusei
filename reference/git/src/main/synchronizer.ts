import { randomUUID } from 'node:crypto'
import { resolve } from 'node:path'
import { ordinaryTaskReadCapability, type BackgroundAgentContext, type RuntimeParticipant, type RuntimeStartContext } from '@mokusei/application-contracts/main'
import { debugError } from '@mokusei/plugin-kit/main'
import { gitContracts, type GitDirectory, type GitObservation, type GitSnapshot } from '../shared/contracts.js'
import { GitReadFailure, type GitClient } from './git-client.js'
import { listGitRecords } from './domain.js'

/** Directory discovery and Git Thread lifecycle require no model or task execution. */
export class GitSynchronizer implements RuntimeParticipant {
  readonly id = 'git.monitor'
  private controller?: AbortController
  private timer?: NodeJS.Timeout
  private running?: Promise<void>
  private lastAttemptAt = 0

  constructor(private readonly context: BackgroundAgentContext, private readonly client: GitClient) {}

  start(context: RuntimeStartContext): void {
    if (this.controller) return
    context.signal.throwIfAborted()
    this.controller = new AbortController()
    this.tick(AbortSignal.any([context.signal, this.controller.signal]))
  }

  async stop(): Promise<void> {
    this.controller?.abort(new Error('Git synchronization stopped'))
    if (this.timer) clearTimeout(this.timer)
    this.timer = undefined
    await this.running
    this.controller = undefined
  }

  private tick(signal: AbortSignal): void {
    if (signal.aborted) return
    this.running = this.runOnce(signal).catch(error => {
      if (!signal.aborted) debugError('git-sync.failed', error)
    }).finally(() => {
      this.running = undefined
      if (!signal.aborted) {
        this.timer = setTimeout(() => this.tick(signal), 5_000)
        this.timer.unref()
      }
    })
  }

  async runOnce(signal: AbortSignal): Promise<void> {
    signal.throwIfAborted()
    const [known, activities, tasks] = await Promise.all([
      listGitRecords(this.context.domain, gitContracts.listDirectories, signal),
      listGitRecords(this.context.domain, gitContracts.list, signal),
      this.context.capabilities.require(ordinaryTaskReadCapability).captureList({ includeArchived: true }, { signal })
    ])
    const directories = new Map<string, GitDirectory>()
    for (const directory of [...known, ...tasks.filter(task => task.cwd && task.tags.directoryTags.length)
      .map(task => ({ cwd: task.cwd, directoryTags: task.tags.directoryTags }))]) {
      const cwd = resolve(directory.cwd)
      directories.set(cwd, { cwd, directoryTags: [...new Set([...directories.get(cwd)?.directoryTags ?? [], ...directory.directoryTags])] })
    }
    const roots = new Map(activities.map(activity => [activity.snapshot.root, new Set(activity.directoryTags)]))
    const discovery = new Map([...directories.values(), ...activities.map(activity => ({
      cwd: activity.snapshot.root, directoryTags: activity.directoryTags
    }))].map(directory => [directory.cwd, directory]))
    const repositories = new Map<string, Promise<readonly string[]>>()
    await concurrent([...discovery.values()], signal, async directory => {
      try {
        for (const root of await this.client.discover(directory.cwd, signal, repositories)) {
          const tags = roots.get(root) ?? new Set<string>()
          for (const tag of directory.directoryTags) tags.add(tag)
          roots.set(root, tags)
        }
      } catch (error) {
        signal.throwIfAborted()
        // Keep the seed and independently re-read known worktrees when discovery fails.
        debugError('git-discovery.failed', error)
      }
    })
    const worktrees = new Map<string, Promise<GitSnapshot>>()
    const observations: GitObservation[] = []
    const attemptedAt = this.lastAttemptAt = Math.max(Date.now(), this.lastAttemptAt + 1)
    await concurrent([...roots], signal, async ([root, tags]) => {
      const base = { root, directoryTags: [...tags], attemptedAt }
      try {
        const snapshot = await this.client.read(root, signal, worktrees)
        // Losing .git can turn an old root into a subdirectory of a different repository.
        observations.push({ ...base, snapshot: snapshot?.root === root ? snapshot : null })
      } catch (error) {
        signal.throwIfAborted()
        observations.push({ ...base, error: error instanceof GitReadFailure ? error.code : 'inaccessible' })
      }
    })
    signal.throwIfAborted()
    await this.context.domain.execute(gitContracts.sync, { directories: [...directories.values()], observations }, { signal, requestId: randomUUID() })
  }
}

async function concurrent<T>(items: readonly T[], signal: AbortSignal, action: (item: T) => Promise<void>): Promise<void> {
  let offset = 0
  const outcomes = await Promise.allSettled(Array.from({ length: 2 }, async () => {
    while (offset < items.length) { signal.throwIfAborted(); await action(items[offset++]) }
  }))
  const failures = outcomes.flatMap(result => result.status === 'rejected' ? [result.reason] : [])
  if (failures.length) throw new AggregateError(failures, 'Git observation failed')
}
