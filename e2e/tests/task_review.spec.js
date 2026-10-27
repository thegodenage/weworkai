const { test, expect } = require("@playwright/test")
const {
  AGENT_WAIT,
  CONNECTOR,
  createAgent,
  createConnector,
  removeTasks,
  setColorScheme,
  unreadCount,
  visitConnected,
} = require("./helpers")

// The full human loop against bin/fake_claude_bridge: plan → comment → revised plan →
// Ready for development → coder → reviewers (Review column) → ready to merge → done, and a
// human dragging it back into review. Agent runs take ~1s each, plus the scheduler's 1s
// tick, so waits are generous. Notifications follow it: toast, bell, panel.
const TITLE_PREFIX = "Greeting "
const AGENTS = [
  { name: "E2E Planner", role: "planner" },
  { name: "E2E Coder", role: "coder" },
  { name: "E2E Reviewer", role: "reviewer" },
  { name: "E2E QA", role: "qa" },
]

test.use({ viewport: { width: 1440, height: 900 } })
test.setTimeout(240_000)

test("a human reviews the plan, asks for changes, then hands it to the coder", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept())

  await createConnector(page)
  for (const agent of AGENTS) await createAgent(page, agent)

  const title = `${TITLE_PREFIX}${Date.now()}`
  await visitConnected(page, "/tasks/new")
  await page.locator("#task-form input[name='form[title]']").fill(title)
  // Both fake reviewers report findings, so the coder goes through every fix round.
  await page.locator("#task-form-description-input").fill("Greet users by name. [fake:findings]")
  await page.locator("#task-form input[name='form[repository]']").fill("/repos/app")
  await page.locator("#task-form").getByRole("button", { name: "Create" }).click()
  await expect(page.locator("#task-form")).toHaveCount(0)

  const card = page.locator("#board article", { hasText: title })
  await card.getByRole("link").click()
  const unreadBefore = await unreadCount(page)
  await page.locator("#task-drawer-status select").selectOption("todo")
  await expect(card.locator("[id$=-working][data-stage=planning]")).toBeVisible()

  // The planner's notifications arrive live: a toast, and the bell counts them.
  const planToast = page.locator("#notification-toasts [data-notification-id]", {
    hasText: `Plan ready: ${title}`,
  })
  await expect(planToast).toBeVisible(AGENT_WAIT)
  await page.locator("#notification-toasts").screenshot({
    path: "test-results/screens/toast.png",
    animations: "disabled",
  })
  await expect.poll(() => unreadCount(page)).toBeGreaterThanOrEqual(unreadBefore + 2)

  await expect(card.locator("[id^=needs-you-]")).toBeVisible(AGENT_WAIT)
  await page.locator("#task-drawer-close").click()
  await expect(page.locator("#task-drawer")).toHaveCount(0)
  await page
    .locator("section[data-status=await_human_supervision]")
    .screenshot({ path: "test-results/screens/board-needs-you.png" })

  // The bell panel opens the task and marks the notification read.
  await page.locator("#notification-bell-button").click()
  const panel = page.locator("#notification-panel")
  await expect(panel).toBeVisible()
  const planNotification = panel.locator("#notification-list a", { hasText: `Plan ready: ${title}` })
  await expect(planNotification).toHaveAttribute("data-unread", "")
  await page.screenshot({ path: "test-results/screens/bell-panel.png", animations: "disabled" })
  await setColorScheme(page, "dark")
  await page.screenshot({ path: "test-results/screens/bell-panel-dark.png", animations: "disabled" })
  await setColorScheme(page, "light")
  const unreadBeforeOpen = await unreadCount(page)
  await planNotification.click()
  await expect(page).toHaveURL(/\/tasks\/[0-9a-f-]+$/)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible()
  await expect.poll(() => unreadCount(page)).toBe(unreadBeforeOpen - 1)

  // The first plan: two steps with diffs and one decision.
  await expect(page.locator("#task-title")).toHaveText(title)
  await expect(page.locator("#task-needs-you")).toBeVisible()
  await expect(page.locator("#plan-summary")).toContainText("Add a greeting helper with a test.")
  await expect(page.locator("#step-s1")).toContainText("Add the Greeting module")
  await expect(page.locator("#diff-s1-0")).toContainText("lib/greeting.ex")
  await expect(page.locator("#diff-s1-0 tr.diff-addition")).toHaveCount(3)
  await expect(page.locator("#plan-decisions-callout")).toBeVisible()
  await page.screenshot({ path: "test-results/screens/plan-view.png", fullPage: true })

  await page.locator("#plan-decisions-callout a").click()
  await expect(page.locator("#question-q1")).toContainText("Should the greeting be localized?")
  await page.locator("#question-q1-option-0").click()
  await page.screenshot({ path: "test-results/screens/decisions.png", fullPage: true })
  await page.locator("#tab-plan").click()

  await page.locator("#step-s2-checkbox").click()
  await page.locator("#diff-s1-0-line-0-1").click()
  await expect(page.locator("#chip-step-s2")).toBeVisible()
  await expect(page.locator("#comment-references")).toContainText("lib/greeting.ex:2")
  await page.locator("#comment-body").fill("Handle a nil name too, and keep it English only.")
  await page.screenshot({ path: "test-results/screens/plan-selection.png", fullPage: true })
  await setColorScheme(page, "dark")
  await page.screenshot({
    path: "test-results/screens/plan-selection-dark.png",
    fullPage: true,
    animations: "disabled",
  })
  await setColorScheme(page, "light")
  await page.locator("#request-changes").click()

  await expect(page.locator("#agent-working")).toBeVisible()
  await expect(page.locator("#review-closed")).toContainText("revising the plan")
  await page.screenshot({ path: "test-results/screens/plan-revising.png", fullPage: true })

  // The planner's revision lands live, without questions this time.
  await expect(page.locator("#plan-summary")).toContainText("Revised plan", AGENT_WAIT)
  await expect(page.locator("#plan-decisions-callout")).toHaveCount(0)
  await expect(page.locator("#comment-form")).toBeVisible()

  await page.locator("#tab-activity").click()
  await expect(page.locator("#messages")).toContainText("Handle a nil name too")
  await page.screenshot({ path: "test-results/screens/activity.png", fullPage: true })
  await page.locator("#tab-plan").click()

  // Other specs may leave coders behind; with several, the toolbar asks which one.
  const coderSelect = page.locator("#approve-coder")
  if ((await coderSelect.count()) > 0) await coderSelect.selectOption({ label: "E2E Coder" })
  await page.locator("#approve-plan").click()
  await expect(page.locator("#task-branch")).toContainText("weworkai/")
  await expect(page.locator("#task-assignee")).toContainText("E2E Coder")

  // While the reviewers work the task sits in Review; findings send it back to the coder.
  await expect(page.locator("#task-status[data-status=review]")).toBeVisible(AGENT_WAIT)
  await expect(page.locator("#agent-working")).toContainText("reviewer")
  await page.screenshot({ path: "test-results/screens/reviewers-working.png", fullPage: true })
  await expect(page.locator("#task-status[data-status=in_progress]")).toBeVisible(AGENT_WAIT)
  await expect(page.locator("#agent-working")).toContainText("fixing the reviewers' findings")

  // After the last fix round the branch waits for the human, findings attached.
  const readyToMerge = page.locator("#ready-to-merge")
  await expect(readyToMerge).toBeVisible({ timeout: 120_000 })
  await expect(page.locator("#task-status[data-status=await_human_supervision]")).toBeVisible()
  await expect(page.locator("#ready-to-merge-branch")).toContainText("weworkai/")
  await expect(readyToMerge).toContainText("findings are still open")
  await expect(page.locator("#agent-working")).toHaveCount(0)

  // The proof of work beside it: the branch's two files, the findings left open per
  // severity, each agent's last report, the runs per stage, and spend against a cap set now.
  const proof = page.locator("#proof-of-work")
  await expect(proof.locator("#pow-files")).toContainText("2")
  await expect(proof.locator("#pow-file-1")).toContainText("test/greeting_test.exs")
  await expect(proof.locator("#pow-lines")).toContainText("+7")
  await expect(proof.locator("#pow-findings-high")).toContainText("2")
  await expect(proof.locator("#pow-report-qa")).toContainText("2 open")
  await expect(proof.locator("#pow-stage-coding td").nth(1)).toHaveText("4")
  await page.locator("#task-budget-edit").click()
  await page.locator("#task-budget-input").fill("5")
  await page.locator("#task-budget-save").click()
  await expect(proof.locator("#pow-budget")).toContainText("/ $5.00")
  await proof.screenshot({ path: "test-results/screens/proof-of-work.png" })
  await setColorScheme(page, "dark")
  await proof.screenshot({ path: "test-results/screens/proof-of-work-dark.png", animations: "disabled" })
  await setColorScheme(page, "light")
  await page.screenshot({ path: "test-results/screens/ready-to-merge.png", fullPage: true })
  await setColorScheme(page, "dark")
  await page.screenshot({
    path: "test-results/screens/ready-to-merge-dark.png",
    fullPage: true,
    animations: "disabled",
  })
  await setColorScheme(page, "light")

  await page.locator("#tab-findings").click()
  await expect(page.locator("#review-round")).toHaveText("Fix round 3 of 3")
  await expect(page.locator("#finding-reviewer-f1")).toContainText("Greeting crashes on nil")
  await expect(page.locator("#finding-qa-f2")).toContainText("lib/greeting.ex:1")
  await page.screenshot({ path: "test-results/screens/findings.png", fullPage: true })

  // Two planner runs, then four rounds of coder, code reviewer and docker reviewer.
  await page.locator("#tab-runs").click()
  await expect(page.locator("#runs li[id^='runs-']:not(#runs-empty)")).toHaveCount(14)
  await page.screenshot({ path: "test-results/screens/runs.png", fullPage: true })

  await page.locator("#mark-done").click()
  await expect(page.locator("#task-status[data-status=done]")).toBeVisible()
  await expect(readyToMerge).toHaveCount(0)

  // Dragged back into review, the code reviewer starts over on the branch.
  const taskId = page.url().match(/\/tasks\/([0-9a-f-]+)/)[1]
  await visitConnected(page, `/tasks/${taskId}/edit`)
  await page.locator("#task-drawer-status select").selectOption("review")
  await expect(page.locator(`#column-review article[data-task-id="${taskId}"]`)).toBeVisible()
  await visitConnected(page, `/tasks/${taskId}`)
  await expect(page.locator("#task-status[data-status=review]")).toBeVisible()
  await expect(page.locator("#agent-working")).toContainText("reviewer")

  // Continue pushes it on from wherever it is: here, its menu marks it done (stopping the review).
  await expect(page.locator("#continue-task")).toContainText("Review")
  await page.locator("#continue-task-toggle").click()
  await expect(page.locator("#continue-task-menu")).toBeVisible()
  await page.screenshot({ path: "test-results/screens/continue-menu.png", animations: "disabled" })
  await page.locator("#continue-task-done").click()
  await expect(page.locator("#task-status[data-status=done]")).toBeVisible()
  await expect(page.locator("#agent-working")).toHaveCount(0)

  await removeTasks(page, title)
})
