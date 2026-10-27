import { realpath, stat } from 'node:fs/promises'
import { resolve } from 'node:path'
import { ApplicationProcessError, type ApplicationProcessCapability } from '@mokusei/application-contracts/main'
import { gitSnapshotSchema, type GitReadError, type GitSnapshot } from '../shared/contracts.js'

export class GitReadFailure extends Error {
  constructor(readonly code: GitReadError) { super(`Local Git read failed: ${code}`) }
}
export interface GitClient {
  discover(cwd: string, signal: AbortSignal, repositories?: Map<string, Promise<readonly string[]>>): Promise<readonly string[]>
  read(cwd: string, signal: AbortSignal, worktrees?: Map<string, Promise<GitSnapshot>>): Promise<GitSnapshot | null>
}

/** Fixed local commands; status discovery never writes Git state or fetches. */
export function createGitClient(process: ApplicationProcessCapability): GitClient {
  let active = 0
  const waiting: (() => void)[] = []
  const release = () => { active--; waiting.shift()?.() }
  const acquire = (signal: AbortSignal): Promise<() => void> => new Promise((resolve, reject) => {
    signal.throwIfAborted()
    const enter = () => { signal.removeEventListener('abort', cancel); active++; resolve(release) }
    const cancel = () => {
      const index = waiting.indexOf(enter)
      if (index >= 0) waiting.splice(index, 1)
      reject(signal.reason)
    }
    if (active < 2) enter()
    else { waiting.push(enter); signal.addEventListener('abort', cancel, { once: true }) }
  })
  const run = (cwd: string, args: readonly string[], signal: AbortSignal) => process.run({
    command: 'git', args: ['--no-optional-locks', '-c', 'core.fsmonitor=false', '-c', 'core.untrackedCache=false', ...args],
    cwd, timeoutMs: 10_000, maxOutputBytes: 8 * 1024 * 1024,
    env: { LC_ALL: 'C', GIT_TERMINAL_PROMPT: '0', GIT_OPTIONAL_LOCKS: '0',
      GIT_DIR: undefined, GIT_WORK_TREE: undefined, GIT_COMMON_DIR: undefined, GIT_INDEX_FILE: undefined,
      GIT_OBJECT_DIRECTORY: undefined, GIT_ALTERNATE_OBJECT_DIRECTORIES: undefined, GIT_NAMESPACE: undefined }
  }, { signal })
  const locate = async (cwd: string, signal: AbortSignal): Promise<string | null> => {
    try { if (!(await stat(cwd)).isDirectory()) return null }
    catch (error) { if (missing(error)) return null; throw error }
    signal.throwIfAborted()
    const location = await run(cwd, ['rev-parse', '--show-toplevel'], signal)
    if (location.exitCode !== 0) {
      if (/not a git repository|must be run in a work tree/u.test(location.stderr)) return null
      throw new GitReadFailure('inaccessible')
    }
    const root = location.stdout.replace(/\r?\n$/u, '')
    if (!root) throw new GitReadFailure('inaccessible')
    return realpath(root)
  }
  const bounded = async <T>(signal: AbortSignal, action: () => Promise<T>): Promise<T> => {
    const release = await acquire(signal)
    try { const result = await action(); signal.throwIfAborted(); return result }
    catch (error) {
      signal.throwIfAborted()
      if (error instanceof GitReadFailure) throw error
      const code = error instanceof ApplicationProcessError ? error.code : undefined
      throw new GitReadFailure(code === 'not-found' ? 'unavailable' : code === 'timeout' ? 'timeout' :
        code === 'output-limit' ? 'too-large' : 'inaccessible')
    } finally { release() }
  }
  return {
    discover: (cwd, signal, repositories) => bounded(signal, async () => {
      const root = await locate(cwd, signal)
      if (!root) return []
      const common = await run(root, ['rev-parse', '--git-common-dir'], signal)
      if (common.exitCode !== 0) throw new GitReadFailure('inaccessible')
      const repository = await realpath(resolve(root, common.stdout.replace(/\r?\n$/u, '')))
      let roots = repositories?.get(repository)
      if (!roots) {
        roots = (async () => {
          const result = await run(root, ['worktree', 'list', '--porcelain', '-z'], signal)
          if (result.exitCode !== 0) throw new GitReadFailure('inaccessible')
          return Promise.all(parseWorktreeRoots(result.stdout).map(async path => {
            try { return await realpath(path) } catch (error) { if (missing(error)) return resolve(path); throw error }
          }))
        })()
        repositories?.set(repository, roots)
      }
      return roots
    }),
    read: (cwd, signal, worktrees) => bounded(signal, async () => {
      const root = await locate(cwd, signal)
      if (!root) return null
      let snapshot = worktrees?.get(root)
      if (!snapshot) {
        snapshot = (async () => {
          const status = await run(root, ['status', '--porcelain=v2', '-z', '--branch', '--ahead-behind',
            '--untracked-files=all', '--ignore-submodules=none'], signal)
          if (status.exitCode !== 0) throw new GitReadFailure('inaccessible')
          return parseGitStatus(root, status.stdout)
        })()
        worktrees?.set(root, snapshot)
      }
      return snapshot
    })
  }
}

function missing(error: unknown): boolean {
  return error instanceof Error && 'code' in error && (error.code === 'ENOENT' || error.code === 'ENOTDIR')
}

/** Records and fields are NUL-framed, preserving spaces and newlines in worktree paths. */
export function parseWorktreeRoots(output: string): string[] {
  if (!output.endsWith('\0')) throw new GitReadFailure('inaccessible')
  const roots: string[] = []
  let root: string | undefined, bare = false
  for (const field of output.split('\0')) {
    if (field.startsWith('worktree ')) root = field.slice(9)
    else if (field === 'bare') bare = true
    else if (!field) {
      if (root && !bare) roots.push(root)
      root = undefined; bare = false
    }
  }
  return roots
}

/** NUL framing preserves spaces/newlines and consumes the extra rename origin record. */
export function parseGitStatus(root: string, output: string): GitSnapshot {
  let branch: string | null = null, head: string | null = null, upstream: string | null = null
  let ahead: number | null = null, behind: number | null = null
  let changed = 0, staged = 0, unstaged = 0, untracked = 0, conflicts = 0
  let sawHead = false, sawBranch = false
  const rows = output.split('\0')
  if (rows.pop() !== '') throw new GitReadFailure('inaccessible')
  for (let index = 0; index < rows.length; index++) {
    const row = rows[index]
    if (row.startsWith('# branch.oid ')) {
      const value = row.slice(13)
      if (value !== '(initial)' && !/^[0-9a-f]{40,64}$/u.test(value)) throw new GitReadFailure('inaccessible')
      head = value === '(initial)' ? null : value
      sawHead = true
    } else if (row.startsWith('# branch.head ')) {
      const value = row.slice(14)
      branch = value === '(detached)' ? null : value
      sawBranch = Boolean(value)
    } else if (row.startsWith('# branch.upstream ')) upstream = row.slice(18)
    else if (row.startsWith('# branch.ab ')) {
      const match = /^# branch\.ab \+(\d+) -(\d+)$/u.exec(row)
      if (!match) throw new GitReadFailure('inaccessible')
      ahead = Number(match[1]); behind = Number(match[2])
    } else if (row.startsWith('# ')) continue
    else if (row.startsWith('? ')) { changed++; untracked++ }
    else if (row.startsWith('! ')) continue
    else if (/^[12u] /u.test(row)) {
      const status = row.slice(2, 4)
      if (!/^[.MADRCUT]{2}$/u.test(status) || row[4] !== ' ') throw new GitReadFailure('inaccessible')
      changed++
      if (row[0] === 'u') conflicts++
      else {
        if (status[0] !== '.') staged++
        if (status[1] !== '.') unstaged++
      }
      if (row[0] === '2' && !rows[++index]) throw new GitReadFailure('inaccessible')
    } else throw new GitReadFailure('inaccessible')
  }
  if (!sawHead || !sawBranch) throw new GitReadFailure('inaccessible')
  return gitSnapshotSchema.parse({ root, branch, head, upstream, ahead, behind, changed, staged, unstaged, untracked, conflicts })
}
