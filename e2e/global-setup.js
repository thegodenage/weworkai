// Every run starts from a fresh install: the e2e instance's database keeps only what the
// migrations seeded (Weworkai.E2E; the endpoint answers nowhere else).
module.exports = async () => {
  const base = process.env.BASE_URL ?? "http://web-e2e:4000"
  const response = await fetch(`${base}/e2e/reset`, { method: "POST" })
  if (response.status !== 204) throw new Error(`Resetting the e2e database failed: ${response.status}`)
}
