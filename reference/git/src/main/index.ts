import type { ApplicationMainModule } from '@mokusei/application-contracts/main'
import { applicationProcessCapability, ordinaryTaskReadCapability } from '@mokusei/application-contracts/main'
import manifest from '../manifest.js'
import { registerGitDomain } from './domain.js'
import { registerGitDiffQueries } from './diff-reader.js'
import { createGitClient } from './git-client.js'
import { GitSynchronizer } from './synchronizer.js'

export default {
  manifest,
  register(registry) {
    registerGitDomain(registry)
    registerGitDiffQueries(registry)
    registry.backgroundAgent({ id: 'git.monitor', requires: [ordinaryTaskReadCapability, applicationProcessCapability],
      create: context => new GitSynchronizer(context, createGitClient(context.capabilities.require(applicationProcessCapability))) })
  }
} satisfies ApplicationMainModule
