import fs from 'node:fs';
import path from 'node:path';

function readCredentials(filePath) {
  const credentials = {};
  for (const line of fs.readFileSync(filePath, 'utf8').split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const separator = trimmed.indexOf('=');
    if (separator < 1) continue;
    const key = trimmed.slice(0, separator).trim().toLowerCase();
    let value = trimmed.slice(separator + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    credentials[key] = value;
  }
  return credentials;
}

async function firstVisible(locators) {
  for (const locator of locators) {
    if (await locator.first().isVisible().catch(() => false)) return locator.first();
  }
  return null;
}

export default async ({ page }) => {
  const credentialsPath = process.env.UX_AUTH_CREDENTIALS ||
    path.join(process.cwd(), 'docs', 'ux', '.creds');
  if (!fs.existsSync(credentialsPath)) return;

  const credentials = readCredentials(credentialsPath);
  const baseUrl = credentials.base_url || credentials.frontend_url || credentials.url;
  const email = credentials.email || credentials.username;
  const password = credentials.password;
  if (!baseUrl || !email || !password) return;

  await page.goto(baseUrl, { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(2000);
  let emailInput = await firstVisible([
    credentials.email_selector ? page.locator(credentials.email_selector) : null,
    page.getByLabel(/email|username/i),
    page.locator('input[type="email"]'),
    page.locator('input[name="email"], input[name="username"]'),
  ].filter(Boolean));
  let passwordInput = await firstVisible([
    credentials.password_selector ? page.locator(credentials.password_selector) : null,
    page.getByLabel(/password/i),
    page.locator('input[type="password"]'),
  ].filter(Boolean));

  if (!emailInput || !passwordInput) {
    const portalSignIn = await firstVisible([
      page.getByRole('button', { name: /sign in with cadres portal/i }),
      page.getByRole('link', { name: /sign in with cadres portal/i }),
      page.getByRole('button', { name: /sign in|log in/i }),
      page.getByRole('link', { name: /sign in|log in/i }),
    ]);
    if (portalSignIn) {
      await portalSignIn.click();
      await page.waitForLoadState('domcontentloaded').catch(() => undefined);
      await page.waitForTimeout(1500);
      emailInput = await firstVisible([
        credentials.email_selector ? page.locator(credentials.email_selector) : null,
        page.getByLabel(/email|username/i),
        page.locator('input[type="email"]'),
        page.locator('input[name="email"], input[name="username"]'),
      ].filter(Boolean));
      passwordInput = await firstVisible([
        credentials.password_selector ? page.locator(credentials.password_selector) : null,
        page.getByLabel(/password/i),
        page.locator('input[type="password"]'),
      ].filter(Boolean));
    }
  }
  if (!emailInput || !passwordInput) return;

  await emailInput.fill(email);
  await passwordInput.fill(password);
  const submit = await firstVisible([
    credentials.submit_selector ? page.locator(credentials.submit_selector) : null,
    page.getByRole('button', { name: /^sign in with password$/i }),
    page.locator('button[type="submit"], input[type="submit"]'),
    page.getByRole('button', { name: /^(sign in|log in|continue)$/i }),
  ].filter(Boolean));
  if (!submit) throw new Error('UX authentication submit control was not found.');
  await submit.click();
  await page.waitForLoadState('domcontentloaded').catch(() => undefined);
  await page.waitForTimeout(2500);
};
