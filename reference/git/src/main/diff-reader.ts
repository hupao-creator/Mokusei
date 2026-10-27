import { realpath } from 'node:fs/promises'
import { ApplicationProcessError, applicationProcessCapability,
  type ApplicationProcessCapability, type DomainExternalReadContext, type PluginMainRegistry } from '@mokusei/application-contracts/main'
import { gitContracts } from '../shared/contracts.js'
import { gitDiffContracts, type GitChangedFile, type GitDiffContent, type GitDiffSelection } from '../shared/diff-contracts.js'

const MAX_PATCH_BYTES = 2 * 1024 * 1024
const env = { LC_ALL: 'C', GIT_TERMINAL_PROMPT: '0', GIT_OPTIONAL_LOCKS: '0', GIT_EXTERNAL_DIFF: undefined,
  GIT_DIR: undefined, GIT_WORK_TREE: undefined, GIT_COMMON_DIR: undefined, GIT_INDEX_FILE: undefined,
  GIT_OBJECT_DIRECTORY: undefined, GIT_ALTERNATE_OBJECT_DIRECTORIES: undefined, GIT_NAMESPACE: undefined }

export function registerGitDiffQueries(registry: PluginMainRegistry): void {
  // Bound concurrent reads, including rapid navigation before IPC results return.
  let active = 0
  const waiting: (() => void)[] = []
  async function read<T>(context: DomainExternalReadContext, activityId: string,
    action: (reader: ReturnType<typeof createGitDiffReader>) => Promise<T>): Promise<T> {
    const { signal } = context
    const record = context.snapshot.records.get(gitContracts.worktrees, activityId)
    if (!record || !record.value.available) throw new Error('Git activity is no longer available')
    await new Promise<void>((resolve, reject) => {
      signal.throwIfAborted()
      const enter = () => { signal.removeEventListener('abort', abort); active++; resolve() }
      const abort = () => { const i = waiting.indexOf(enter); if (i >= 0) waiting.splice(i, 1); reject(signal.reason) }
      if (active < 2) enter()
      else { waiting.push(enter); signal.addEventListener('abort', abort, { once: true }) }
    })
    try {
      signal.throwIfAborted()
      const reader = createGitDiffReader(context.capabilities.require(applicationProcessCapability), record.value.snapshot.root, signal)
      await reader.validateRoot()
      return await action(reader)
    } finally { active--; waiting.shift()?.() }
  }
  const definition = { audience: { user: true, background: false }, requires: [applicationProcessCapability] }
  registry.externalQuery({ ...definition, key: gitDiffContracts.files, read: (input, context) =>
    read(context, input.activityId, async reader => ({ files: await reader.files(), readAt: Date.now() })) })
  registry.externalQuery({ ...definition, key: gitDiffContracts.diff, read: (input, context) =>
    read(context, input.activityId, reader => reader.diff(input)) })
}

/** Paths come from fresh NUL-framed status; the renderer cannot request arbitrary files. */
export function createGitDiffReader(process: ApplicationProcessCapability, root: string, signal: AbortSignal) {
  const run = (args: readonly string[], maxOutputBytes = MAX_PATCH_BYTES) => process.run({ command: 'git',
    args: ['--no-optional-locks', '--literal-pathspecs', '-c', 'core.fsmonitor=false', '-c', 'core.untrackedCache=false',
      '-c', 'core.quotePath=true', ...args], cwd: root, env, timeoutMs: 10_000, maxOutputBytes }, { signal })
  const files = async () => {
    const result = await run(['status', '--porcelain=v2', '-z', '--untracked-files=all', '--ignore-submodules=none'], 8 * 1024 * 1024)
    if (result.exitCode !== 0) throw new Error('Cannot read Git worktree status')
    return parseChangedFiles(result.stdout)
  }
  return {
    async validateRoot() {
      const result = await run(['rev-parse', '--show-toplevel'])
      if (result.exitCode !== 0 || await realpath(result.stdout.replace(/\r?\n$/u, '')) !== root || await realpath(root) !== root) {
        throw new Error('Git worktree is no longer available')
      }
    },
    files,
    async diff(input: GitDiffSelection): Promise<GitDiffContent> {
      const file = (await files()).find(file => file.path === input.path && file.scope === input.scope)
      if (!file) throw new Error('This file changed; refresh the file list')
      if (file.scope === 'conflicts') return { patch: '', notice: 'conflict' }
      const options = ['--no-ext-diff', '--no-textconv', '--no-color', '--no-relative', '--src-prefix=a/', '--dst-prefix=b/', '--unified=3']
      try {
        const result = await run(file.scope === 'untracked'
          ? ['diff', '--no-index', ...options, '--', '/dev/null', file.path]
          : ['diff', ...(file.scope === 'staged' ? ['--cached'] : []), ...options, '--submodule=short', '--',
            ...(file.oldPath ? [file.oldPath] : []), file.path])
        if (result.exitCode !== 0 && !(file.scope === 'untracked' && result.exitCode === 1)) throw new Error('Cannot read this Git diff')
        if (/^Binary files .* differ$|^GIT binary patch$/mu.test(result.stdout)) return { patch: '', notice: 'binary' }
        return { patch: result.stdout, notice: result.stdout ? null : file.submodule ? 'submodule' : 'empty' }
      } catch (error) {
        if (error instanceof ApplicationProcessError && error.code === 'output-limit') return { patch: '', notice: 'too-large' }
        throw error
      }
    }
  }
}

export function parseChangedFiles(output: string): GitChangedFile[] {
  if (output && !output.endsWith('\0')) throw new Error('Invalid Git status response')
  const rows = output.split('\0')
  const files: GitChangedFile[] = []
  for (let i = 0; i < rows.length - 1; i++) {
    const row = rows[i]
    if (row.startsWith('? ')) {
      files.push({ path: row.slice(2), oldPath: null, status: 'A', scope: 'untracked', submodule: false })
      continue
    }
    if (!/^[12u] /u.test(row)) continue
    const fields = row[0] === '1' ? 8 : row[0] === '2' ? 9 : 10
    let offset = 0
    for (let field = 0; field < fields; field++) {
      offset = row.indexOf(' ', offset) + 1
      if (!offset) throw new Error('Invalid Git status entry')
    }
    const path = row.slice(offset)
    const oldPath = row[0] === '2' ? rows[++i] : null
    if (!path || oldPath === '') throw new Error('Invalid Git status path')
    const base = { path, oldPath: oldPath ?? null, submodule: row[5] === 'S' }
    const status = row.slice(2, 4)
    if (row[0] === 'u') files.push({ ...base, status, scope: 'conflicts' })
    else {
      if (status[0] !== '.') files.push({ ...base, status: status[0], scope: 'staged' })
      if (status[1] !== '.') files.push({ ...base, oldPath: null, status: status[1], scope: 'unstaged' })
    }
  }
  return files
}
