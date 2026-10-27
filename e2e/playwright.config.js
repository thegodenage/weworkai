const { defineConfig, devices } = require("@playwright/test")

module.exports = defineConfig({
  testDir: "./tests",
  globalSetup: "./global-setup.js",
  outputDir: "./test-results",
  reporter: "list",
  use: {
    baseURL: process.env.BASE_URL ?? "http://web-e2e:4000",
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
      testIgnore: /qa_regressions|start_failures|cost_ledger|budget|dependencies|workflows|workflow_editor|ask\.spec/,
    },
    // Read or create notifications, which task_review.spec.js counts on the shared bell; run after it.
    {
      name: "chromium-after",
      use: { ...devices["Desktop Chrome"] },
      testMatch: /qa_regressions|start_failures|cost_ledger|budget|dependencies|workflows|workflow_editor/,
      dependencies: ["chromium"],
    },
    // Any runnable planner answers questions, and the specs before remove their own agents.
    {
      name: "chromium-last",
      use: { ...devices["Desktop Chrome"] },
      testMatch: /ask\.spec/,
      dependencies: ["chromium-after"],
    },
  ],
})
