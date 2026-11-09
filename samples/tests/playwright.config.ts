import {defineConfig} from '@playwright/test';
import './support/environment';

export default defineConfig({
  testDir:'./specs',
  testMatch:'**/*.spec.ts',
  globalSetup:require.resolve('./support/global-setup'),
  fullyParallel:false,
  workers:1,
  retries:0,
  timeout:90_000,
  expect:{timeout:15_000},
  use:{
    browserName:'chromium',
    ignoreHTTPSErrors:false,
    trace:'off',
    screenshot:'off',
    video:'off',
  },
  reporter:[['list'],['./support/json-reporter.ts']],
  outputDir:'./results/artifacts',
});
