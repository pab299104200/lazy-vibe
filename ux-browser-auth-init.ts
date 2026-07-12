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

async function gotoWithRetry(page, url) {
  let lastError;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
      return;
    } catch (error) {
      lastError = error;
      if (attempt === 0) await page.waitForTimeout(1500);
    }
  }
  throw lastError;
}

function absoluteHttpUrl(value) {
  const trimmed = value.trim();
  if (/^https?:\/\//i.test(trimmed)) return trimmed;
  return `https://${trimmed}`;
}

async function armAuditActivityHeartbeat(page) {
  await page.evaluate(() => {
    const key = '__uxAuditActivityHeartbeat';
    if (window[key]) return;
    window[key] = window.setInterval(() => {
      window.dispatchEvent(new Event('pointerdown'));
    }, 60_000);
  });
}

export default async ({ page }) => {
  const credentialsPath = process.env.UX_AUTH_CREDENTIALS ||
    path.join(process.cwd(), 'docs', 'ux', '.creds');
  if (!fs.existsSync(credentialsPath)) return;

  const credentials = readCredentials(credentialsPath);
  const configuredBaseUrl = credentials.base_url || credentials.frontend_url || credentials.url;
  const email = credentials.email || credentials.username;
  const password = credentials.password;
  if (!configuredBaseUrl || !email || !password) return;
  const baseUrl = absoluteHttpUrl(configuredBaseUrl);

  const portalUrl = process.env.UX_AUTH_PORTAL_URL
    ? absoluteHttpUrl(process.env.UX_AUTH_PORTAL_URL)
    : undefined;
  if (portalUrl) {
    await gotoWithRetry(page, `${portalUrl.replace(/\/$/, '')}/login`);
    await page.waitForTimeout(1500);
    const portalEmail = await firstVisible([
      credentials.email_selector ? page.locator(credentials.email_selector) : null,
      page.getByLabel(/email|username/i),
      page.locator('input[type="email"]'),
      page.locator('input[name="email"], input[name="username"]'),
    ].filter(Boolean));
    const portalPassword = await firstVisible([
      credentials.password_selector ? page.locator(credentials.password_selector) : null,
      page.getByLabel(/password/i),
      page.locator('input[type="password"]'),
    ].filter(Boolean));
    if (!portalEmail || !portalPassword) {
      throw new Error('UX Portal authentication fields were not found.');
    }
    await portalEmail.fill(email);
    await portalPassword.fill(password);
    const portalSubmit = await firstVisible([
      page.getByRole('button', { name: /^sign in with password$/i }),
      page.locator('form button[type="submit"], form input[type="submit"]'),
    ]);
    if (!portalSubmit) throw new Error('UX Portal password submit control was not found.');
    await portalSubmit.click();
    await page.waitForLoadState('domcontentloaded').catch(() => undefined);
    await page.waitForTimeout(2000);
    if (new URL(page.url()).pathname.startsWith('/login')) {
      throw new Error('UX Portal authentication did not leave the login page.');
    }
  }

  await gotoWithRetry(page, baseUrl);
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
  if (!emailInput || !passwordInput) {
    await armAuditActivityHeartbeat(page);
    return;
  }

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
  await armAuditActivityHeartbeat(page);
};
