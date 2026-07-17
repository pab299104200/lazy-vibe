#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

function parseArgs(argv) {
  const args = {};
  for (let index = 2; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key.startsWith('--') || value === undefined) {
      throw new Error(`Invalid argument near ${key}`);
    }
    args[key.slice(2)] = value;
  }
  return args;
}

function readCredentialUrl(repoRoot) {
  const credentials = readCredentials(repoRoot);
  return credentials.base_url || credentials.frontend_url || credentials.url || '';
}

function readCredentials(repoRoot) {
  const credentialsPath = path.join(repoRoot, 'docs', 'ux', '.creds');
  if (!fs.existsSync(credentialsPath)) return {};
  const credentials = {};
  const lines = fs.readFileSync(credentialsPath, 'utf8').split(/\r?\n/);
  for (const line of lines) {
    const match = line.match(/^\s*([^#=]+?)\s*=\s*(.*?)\s*$/);
    if (!match) continue;
    credentials[match[1].trim().toLowerCase()] = match[2].replace(/^['"]|['"]$/g, '');
  }
  return credentials;
}

async function hasAuthenticatedSurface(page, credentials, expectedUrl, timeout = 15000) {
  const authenticatedSelector = credentials.authenticated_selector ||
    'nav, [role="navigation"], [data-app-shell]';
  const surface = page.locator(authenticatedSelector).first();
  const hasSurface = await surface.waitFor({ state: 'visible', timeout })
    .then(() => true, () => false);
  if (!hasSurface) return false;

  let currentOrigin;
  let expectedOrigin;
  try {
    currentOrigin = new URL(page.url()).origin;
    expectedOrigin = new URL(expectedUrl).origin;
  } catch {
    return false;
  }
  if (currentOrigin !== expectedOrigin) return false;

  const passwordInput = page.locator('input[type="password"]').first();
  return !(await passwordInput.isVisible().catch(() => false));
}

async function waitForAuthenticationThrottle(throttle) {
  if (throttle.retryAfter <= 0) return;
  const delaySeconds = Math.min(throttle.retryAfter, 30);
  throttle.retryAfter = 0;
  throttle.path = '';
  await new Promise((resolve) => setTimeout(resolve, delaySeconds * 1000));
}

async function authenticate(page, credentials, throttle, expectedUrl) {
  const email = credentials.email || credentials.username;
  if (!email || !credentials.password) return false;
  const emailSelector = credentials.email_selector ||
    'input[type="email"], input[name="email"], input[name="username"]';
  const passwordSelector = credentials.password_selector || 'input[type="password"]';
  const emailInput = page.locator(emailSelector).first();
  const passwordInput = page.locator(passwordSelector).first();
  await waitForAuthenticationThrottle(throttle);
  if (await hasAuthenticatedSurface(page, credentials, expectedUrl)) return true;
  let hasLogin = await passwordInput.waitFor({ state: 'visible', timeout: 30000 })
    .then(() => true, () => false);
  if (!hasLogin) {
    const portalSignIn = page.getByRole('button', { name: /sign in with cadres portal/i })
      .or(page.getByRole('link', { name: /sign in with cadres portal/i })).first();
    if (await portalSignIn.isVisible().catch(() => false)) {
      await portalSignIn.click();
      await page.waitForLoadState('domcontentloaded').catch(() => undefined);
      hasLogin = await passwordInput.waitFor({ state: 'visible', timeout: 30000 })
        .then(() => true, () => false);
    }
  }
  if (!hasLogin && throttle.retryAfter > 0) {
    throw new Error(`Authentication is rate limited at ${throttle.path}; retry after ${throttle.retryAfter} seconds.`);
  }
  if (!hasLogin) {
    await page.reload({ waitUntil: 'domcontentloaded', timeout: 45000 });
    hasLogin = await passwordInput.waitFor({ state: 'visible', timeout: 30000 })
      .then(() => true, () => false);
  }
  if (!hasLogin) return false;
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    await emailInput.fill(email);
    await passwordInput.fill(credentials.password);
    const submit = credentials.submit_selector
      ? page.locator(credentials.submit_selector).first()
      : page.getByRole('button', { name: /^(sign in with password|sign in|log in|continue)$/i }).first();
    await submit.click();
    await passwordInput.waitFor({ state: 'hidden', timeout: 15000 }).catch(() => undefined);
    await page.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => undefined);
    if (!(await passwordInput.isVisible().catch(() => false))) return true;
    if (throttle.retryAfter <= 0 || attempt === 3) break;
    await waitForAuthenticationThrottle(throttle);
  }
  if (throttle.retryAfter > 0) {
    throw new Error(`Authentication remained rate limited after bounded retries at ${throttle.path}.`);
  }
  throw new Error('Configured browser credentials were rejected or login did not advance.');
}

function resolvePlaywright(repoRoot) {
  const searchPaths = [path.join(repoRoot, 'frontend'), repoRoot];
  try {
    return require(require.resolve('playwright', { paths: searchPaths }));
  } catch {
    return null;
  }
}

function installChromium(repoRoot, summaryLog) {
  const frontendRoot = path.join(repoRoot, 'frontend');
  const packageRoot = fs.existsSync(path.join(frontendRoot, 'package.json')) ? frontendRoot : repoRoot;
  summaryLog.push(`Installing the Playwright-version-matched Chromium from ${packageRoot}.`);
  const result = spawnSync('npx', ['playwright', 'install', 'chromium'], {
    cwd: packageRoot,
    encoding: 'utf8',
    timeout: 600000,
  });
  if (result.status !== 0) {
    const detail = (result.stderr || result.stdout || 'install failed').trim().split(/\r?\n/).slice(-8).join('\n');
    throw new Error(`Playwright Chromium installation failed:\n${detail}`);
  }
}

function writeSummary(outDir, status, details) {
  fs.mkdirSync(outDir, { recursive: true });
  const markdown = ['# UX Browser Preflight', '', `STATUS: ${status}`, '', ...details, ''].join('\n');
  fs.writeFileSync(path.join(outDir, 'summary.md'), markdown);
  fs.writeFileSync(path.join(outDir, 'summary.json'), JSON.stringify({ status, details }, null, 2) + '\n');
}

async function main() {
  const args = parseArgs(process.argv);
  const repoRoot = path.resolve(args['repo-root']);
  const outDir = path.join(path.resolve(args['run-dir']), 'artifacts', 'browser-preflight');
  fs.mkdirSync(outDir, { recursive: true });
  const details = [];
  const credentials = readCredentials(repoRoot);
  const baseUrl = process.env.UX_BROWSER_BASE_URL || process.env.AUDIT_BROWSER_BASE_URL ||
    process.env.E2E_BASE_URL || readCredentialUrl(repoRoot);
  if (!baseUrl) throw new Error('No deployed browser URL found in environment or docs/ux/.creds.');

  let playwright = resolvePlaywright(repoRoot);
  if (!playwright) throw new Error('The product does not have Playwright installed.');
  let executablePath = playwright.chromium.executablePath();
  if (!fs.existsSync(executablePath)) {
    if (args['auto-install'] !== '1') throw new Error(`Chromium is missing at ${executablePath}.`);
    installChromium(repoRoot, details);
    playwright = resolvePlaywright(repoRoot);
    executablePath = playwright.chromium.executablePath();
  }
  if (!fs.existsSync(executablePath)) throw new Error(`Chromium remains missing at ${executablePath}.`);

  const browser = await playwright.chromium.launch({ headless: true });
  try {
    const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
    const page = await context.newPage();
    const throttle = { path: '', retryAfter: 0 };
    page.on('response', (browserResponse) => {
      if (browserResponse.status() !== 429) return;
      throttle.path = new URL(browserResponse.url()).pathname;
      throttle.retryAfter = Number.parseInt(browserResponse.headers()['retry-after'] || '0', 10) || 0;
    });
    const portalUrl = process.env.UX_AUTH_PORTAL_URL;
    if (portalUrl && (credentials.email || credentials.username)) {
      const portalLoginUrl = `${portalUrl.replace(/\/$/, '')}/login`;
      await page.goto(portalLoginUrl, { waitUntil: 'domcontentloaded', timeout: 45000 });
      const portalAuthenticated = await authenticate(page, credentials, throttle, portalLoginUrl);
      if (!portalAuthenticated) {
        throw new Error(`Configured Portal fixture credentials could not reach a login form at ${portalLoginUrl}.`);
      }
      details.push('Portal fixture session was authenticated for disposable tenant and identity provisioning.');
    }
    const response = await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 45000 });
    await page.screenshot({ path: path.join(outDir, 'entry-page.png'), fullPage: true });
    const status = response ? response.status() : 0;
    if (status >= 500 || status === 0) throw new Error(`Deployed entry point returned HTTP ${status || 'unknown'}.`);
    details.push(`Deployed entry point reached successfully with HTTP ${status}.`);
    details.push(`Browser engine: ${playwright.chromium.name()} at ${executablePath}.`);
    details.push('A first-page screenshot was captured without persisting credentials.');
    if (credentials.email || credentials.username) {
      const authenticated = await authenticate(page, credentials, throttle, baseUrl);
      if (!authenticated) {
        throw new Error(`Configured browser credentials exist but no login form was reached at ${page.url()} (${await page.title() || 'untitled page'}).`);
      }
      await context.storageState({ path: path.join(outDir, 'auth-state.json') });
      details.push('Authenticated browser state was verified and stored for isolated journey lanes.');
    }
    writeSummary(outDir, 'PASS', details);
  } finally {
    await browser.close();
  }
}

if (require.main === module) main().catch((error) => {
  const args = (() => { try { return parseArgs(process.argv); } catch { return {}; } })();
  const runDir = args['run-dir'] ? path.resolve(args['run-dir']) : process.cwd();
  const outDir = path.join(runDir, 'artifacts', 'browser-preflight');
  writeSummary(outDir, 'FAIL', [String(error && error.message ? error.message : error)]);
  process.exitCode = 1;
});

module.exports = { authenticate, hasAuthenticatedSurface, waitForAuthenticationThrottle };
