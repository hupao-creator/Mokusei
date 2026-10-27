import type { ApplicationPluginManifest } from '@mokusei/application-contracts'

export default {
  id: 'git', displayName: 'Git', apiVersion: 1,
  contributes: {
    backgroundAgents: ['git.monitor'], threadTypes: ['git.activity'], settings: [],
    collections: ['git.directories', 'git.worktrees'], queries: ['git.list', 'git.list-directories', 'git.files', 'git.diff'], commands: ['git.sync']
  }
} as const satisfies ApplicationPluginManifest
